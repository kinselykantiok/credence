
import { describe, expect, it } from "vitest";
import {
  Cl,
  ClarityType,
  ClarityValue,
  isClarityType,
  TupleCV,
} from "@stacks/transactions";
import { tx } from "@hirosystems/clarinet-sdk";

const CONTRACT = "credence";

const BASE_INTEREST_RATE = 500n;
const PLATFORM_FEE_RATE = 100n;
const MAX_DURATION = 52560n;
const MIN_DURATION = 144n;
const DAILY_LOAN_LIMIT = 3;

const ERR_NOT_APPROVED = 104n;
const ERR_CONTRACT_PAUSED = 112n;
const ERR_RATE_LIMITED = 114n;
const ERR_ALREADY_PROCESSED = 115n;

function getAccount(accounts: Map<string, string>, name: string): string {
  const account = accounts.get(name);
  if (!account) {
    throw new Error(`missing account: ${name}`);
  }
  return account;
}

function unwrapSomeTuple(value: ClarityValue, label: string): TupleCV {
  if (!isClarityType(value, ClarityType.OptionalSome)) {
    throw new Error(`${label} expected optional some`);
  }
  const inner = value.value;
  if (!isClarityType(inner, ClarityType.Tuple)) {
    throw new Error(`${label} expected tuple`);
  }
  return inner;
}

function getUint(value: ClarityValue, label: string): bigint {
  if (!isClarityType(value, ClarityType.UInt)) {
    throw new Error(`${label} expected uint`);
  }
  return BigInt(value.value);
}

function calculateRiskMultiplier(creditScore: bigint): bigint {
  if (creditScore > 700n) return 100n;
  if (creditScore > 500n) return 150n;
  return 200n;
}

function calculateLoanTerms(amount: bigint, duration: bigint, creditScore: bigint) {
  const riskMultiplier = calculateRiskMultiplier(creditScore);
  const finalInterestRate = (BASE_INTEREST_RATE * riskMultiplier) / 100n;
  const annualInterest = (amount * finalInterestRate) / 10000n;
  const durationFactor = duration / MAX_DURATION;
  const interest = (annualInterest * durationFactor) / 1n;
  const totalRepayment = amount + interest;
  const platformFee = (totalRepayment * PLATFORM_FEE_RATE) / 10000n;

  return {
    riskMultiplier,
    finalInterestRate,
    interest,
    totalRepayment,
    platformFee,
  };
}

function readLoan(borrower: string): TupleCV {
  const { result } = simnet.callReadOnlyFn(
    CONTRACT,
    "get-loan",
    [Cl.principal(borrower)],
    borrower,
  );
  return unwrapSomeTuple(result, "loan");
}

function readVoteCount(borrower: string): TupleCV {
  const { result } = simnet.callReadOnlyFn(
    CONTRACT,
    "get-vote-count",
    [Cl.principal(borrower)],
    borrower,
  );
  return unwrapSomeTuple(result, "vote-count");
}

function readLpDeposit(provider: string): TupleCV {
  const { result } = simnet.callReadOnlyFn(
    CONTRACT,
    "get-lp-deposit",
    [Cl.principal(provider)],
    provider,
  );
  return unwrapSomeTuple(result, "lp-deposit");
}

function readBorrowerReputation(borrower: string): TupleCV {
  const { result } = simnet.callReadOnlyFn(
    CONTRACT,
    "get-borrower-reputation",
    [Cl.principal(borrower)],
    borrower,
  );
  return unwrapSomeTuple(result, "borrower-reputation");
}

function mineBlocksUntil(height: bigint) {
  while (BigInt(simnet.blockHeight) <= height) {
    simnet.mineBlock([]);
  }
}

describe("credence core flows", () => {
  it("applies a loan and stores computed terms", () => {
    const accounts = simnet.getAccounts();
    const borrower = getAccount(accounts, "wallet_1");
    const amount = 2_000_000n;
    const duration = MAX_DURATION;
    const creditScore = 500n;

    const terms = calculateLoanTerms(amount, duration, creditScore);

    const apply = simnet.callPublicFn(
      CONTRACT,
      "apply-loan",
      [Cl.uint(amount), Cl.uint(duration)],
      borrower,
    );

    expect(apply.result).toBeOk(Cl.uint(terms.totalRepayment));

    const loan = readLoan(borrower);
    expect(loan.value.amount).toBeUint(amount);
    expect(loan.value.duration).toBeUint(duration);
    expect(loan.value.approved).toBeBool(false);
    expect(loan.value.disbursed).toBeBool(false);
    expect(loan.value.repaid).toBeBool(false);
    expect(loan.value["interest-rate"]).toBeUint(terms.finalInterestRate);
    expect(loan.value["total-repayment"]).toBeUint(terms.totalRepayment);
    expect(loan.value["platform-fee"]).toBeUint(terms.platformFee);

    const requestTime = getUint(loan.value["request-time"], "request-time");
    const dueTime = getUint(loan.value["due-time"], "due-time");
    expect(dueTime).toBe(requestTime + duration);

    const votes = readVoteCount(borrower);
    expect(votes.value["yes-votes"]).toBeUint(0n);
    expect(votes.value["no-votes"]).toBeUint(0n);
  });

  it("rate limits loan applications per day", () => {
    const accounts = simnet.getAccounts();
    const borrower = getAccount(accounts, "wallet_1");
    const amount = 1_000_000n;
    const duration = MIN_DURATION;
    const terms = calculateLoanTerms(amount, duration, 500n);

    for (let i = 0; i < DAILY_LOAN_LIMIT; i += 1) {
      const call = simnet.callPublicFn(
        CONTRACT,
        "apply-loan",
        [Cl.uint(amount), Cl.uint(duration)],
        borrower,
      );
      expect(call.result).toBeOk(Cl.uint(terms.totalRepayment));
    }

    const limited = simnet.callPublicFn(
      CONTRACT,
      "apply-loan",
      [Cl.uint(amount), Cl.uint(duration)],
      borrower,
    );
    expect(limited.result).toBeErr(Cl.uint(ERR_RATE_LIMITED));
  });

  it("gates disbursement on audit approvals and pool balance", () => {
    const accounts = simnet.getAccounts();
    const deployer = getAccount(accounts, "deployer");
    const borrower = getAccount(accounts, "wallet_1");
    const auditor1 = getAccount(accounts, "wallet_2");
    const auditor2 = getAccount(accounts, "wallet_3");
    const lp = getAccount(accounts, "wallet_4");

    const depositAmount = 5_000_000n;
    const loanAmount = 2_000_000n;
    const duration = MAX_DURATION;
    const terms = calculateLoanTerms(loanAmount, duration, 500n);

    const deposit = simnet.callPublicFn(
      CONTRACT,
      "deposit-liquidity",
      [Cl.uint(depositAmount)],
      lp,
    );
    expect(deposit.result).toBeOk(Cl.bool(true));

    const apply = simnet.callPublicFn(
      CONTRACT,
      "apply-loan",
      [Cl.uint(loanAmount), Cl.uint(duration)],
      borrower,
    );
    expect(apply.result).toBeOk(Cl.uint(terms.totalRepayment));

    const audit1 = simnet.callPublicFn(
      CONTRACT,
      "audit-borrower",
      [Cl.principal(borrower), Cl.bool(true)],
      auditor1,
    );
    expect(audit1.result).toBeOk(Cl.bool(true));

    const disburseEarly = simnet.callPublicFn(
      CONTRACT,
      "disburse-loan",
      [Cl.principal(borrower)],
      deployer,
    );
    expect(disburseEarly.result).toBeErr(Cl.uint(ERR_NOT_APPROVED));

    const audit2 = simnet.callPublicFn(
      CONTRACT,
      "audit-borrower",
      [Cl.principal(borrower), Cl.bool(true)],
      auditor2,
    );
    expect(audit2.result).toBeOk(Cl.bool(true));

    const disburse = simnet.callPublicFn(
      CONTRACT,
      "disburse-loan",
      [Cl.principal(borrower)],
      deployer,
    );
    expect(disburse.result).toBeOk(Cl.bool(true));

    const loan = readLoan(borrower);
    expect(loan.value.approved).toBeBool(true);
    expect(loan.value.disbursed).toBeBool(true);

    const votes = readVoteCount(borrower);
    expect(votes.value["yes-votes"]).toBeUint(2n);

    const poolBalance = simnet.getDataVar(CONTRACT, "pool-balance");
    expect(poolBalance).toBeUint(depositAmount - loanAmount);
  });

  it("handles repayment and updates reputation", () => {
    const accounts = simnet.getAccounts();
    const deployer = getAccount(accounts, "deployer");
    const borrower = getAccount(accounts, "wallet_1");
    const auditor1 = getAccount(accounts, "wallet_2");
    const auditor2 = getAccount(accounts, "wallet_3");
    const lp = getAccount(accounts, "wallet_4");

    const depositAmount = 5_000_000n;
    const loanAmount = 2_000_000n;
    const duration = MAX_DURATION;
    const terms = calculateLoanTerms(loanAmount, duration, 500n);

    simnet.callPublicFn(CONTRACT, "deposit-liquidity", [Cl.uint(depositAmount)], lp);
    simnet.callPublicFn(
      CONTRACT,
      "apply-loan",
      [Cl.uint(loanAmount), Cl.uint(duration)],
      borrower,
    );
    simnet.callPublicFn(
      CONTRACT,
      "audit-borrower",
      [Cl.principal(borrower), Cl.bool(true)],
      auditor1,
    );
    simnet.callPublicFn(
      CONTRACT,
      "audit-borrower",
      [Cl.principal(borrower), Cl.bool(true)],
      auditor2,
    );
    simnet.callPublicFn(CONTRACT, "disburse-loan", [Cl.principal(borrower)], deployer);

    const repay = simnet.callPublicFn(CONTRACT, "repay-loan", [], borrower);
    expect(repay.result).toBeOk(Cl.bool(true));

    const loan = readLoan(borrower);
    expect(loan.value.repaid).toBeBool(true);

    const poolBalance = simnet.getDataVar(CONTRACT, "pool-balance");
    const expectedPool = depositAmount - loanAmount + (terms.totalRepayment - terms.platformFee);
    expect(poolBalance).toBeUint(expectedPool);

    const interestEarned = simnet.getDataVar(CONTRACT, "total-interest-earned");
    expect(interestEarned).toBeUint(terms.interest);

    const reputation = readBorrowerReputation(borrower);
    expect(reputation.value["total-loans"]).toBeUint(1n);
    expect(reputation.value["successful-repayments"]).toBeUint(1n);
    expect(reputation.value.defaults).toBeUint(0n);
    expect(reputation.value["credit-score"]).toBeUint(500n);
  });

  it("tracks LP withdrawals and blocks same-block double withdrawal", () => {
    const accounts = simnet.getAccounts();
    const lp = getAccount(accounts, "wallet_1");
    const depositAmount = 3_000_000n;
    const withdrawAmount = 1_000_000n;

    const deposit = simnet.callPublicFn(
      CONTRACT,
      "deposit-liquidity",
      [Cl.uint(depositAmount)],
      lp,
    );
    expect(deposit.result).toBeOk(Cl.bool(true));

    const [first, second] = simnet.mineBlock([
      tx.callPublicFn(CONTRACT, "withdraw-liquidity", [Cl.uint(withdrawAmount)], lp),
      tx.callPublicFn(CONTRACT, "withdraw-liquidity", [Cl.uint(withdrawAmount)], lp),
    ]);

    expect(first.result).toBeOk(Cl.bool(true));
    expect(second.result).toBeErr(Cl.uint(ERR_ALREADY_PROCESSED));

    const poolBalance = simnet.getDataVar(CONTRACT, "pool-balance");
    expect(poolBalance).toBeUint(depositAmount - withdrawAmount);

    const lpDeposit = readLpDeposit(lp);
    expect(lpDeposit.value.deposit).toBeUint(depositAmount - withdrawAmount);
  });

  it("slashes backers after overdue, unpaid loans", () => {
    const accounts = simnet.getAccounts();
    const deployer = getAccount(accounts, "deployer");
    const borrower = getAccount(accounts, "wallet_1");
    const backer = getAccount(accounts, "wallet_2");
    const auditor1 = getAccount(accounts, "wallet_3");
    const auditor2 = getAccount(accounts, "wallet_4");
    const lp = getAccount(accounts, "wallet_5");

    const depositAmount = 3_000_000n;
    const loanAmount = 1_000_000n;
    const duration = MIN_DURATION;

    simnet.callPublicFn(CONTRACT, "deposit-liquidity", [Cl.uint(depositAmount)], lp);
    simnet.callPublicFn(
      CONTRACT,
      "apply-loan",
      [Cl.uint(loanAmount), Cl.uint(duration)],
      borrower,
    );
    simnet.callPublicFn(
      CONTRACT,
      "back-borrower",
      [Cl.principal(borrower), Cl.uint(500_000n)],
      backer,
    );
    simnet.callPublicFn(
      CONTRACT,
      "audit-borrower",
      [Cl.principal(borrower), Cl.bool(true)],
      auditor1,
    );
    simnet.callPublicFn(
      CONTRACT,
      "audit-borrower",
      [Cl.principal(borrower), Cl.bool(true)],
      auditor2,
    );
    simnet.callPublicFn(CONTRACT, "disburse-loan", [Cl.principal(borrower)], deployer);

    const loan = readLoan(borrower);
    const dueTime = getUint(loan.value["due-time"], "due-time");
    mineBlocksUntil(dueTime);

    const slash = simnet.callPublicFn(
      CONTRACT,
      "slash-backer",
      [Cl.principal(borrower), Cl.principal(backer)],
      deployer,
    );
    expect(slash.result).toBeOk(Cl.bool(true));

    const backerStake = simnet.callReadOnlyFn(
      CONTRACT,
      "get-backer-stake",
      [Cl.principal(borrower), Cl.principal(backer)],
      backer,
    );
    expect(backerStake.result).toBeNone();

    const reputation = readBorrowerReputation(borrower);
    expect(reputation.value["total-loans"]).toBeUint(1n);
    expect(reputation.value.defaults).toBeUint(1n);
  });

  it("respects emergency pause and unpause", () => {
    const accounts = simnet.getAccounts();
    const deployer = getAccount(accounts, "deployer");
    const borrower = getAccount(accounts, "wallet_1");

    const pause = simnet.callPublicFn(CONTRACT, "emergency-pause", [], deployer);
    expect(pause.result).toBeOk(Cl.bool(true));

    const blocked = simnet.callPublicFn(
      CONTRACT,
      "apply-loan",
      [Cl.uint(1_000_000n), Cl.uint(MIN_DURATION)],
      borrower,
    );
    expect(blocked.result).toBeErr(Cl.uint(ERR_CONTRACT_PAUSED));

    const unpause = simnet.callPublicFn(CONTRACT, "emergency-unpause", [], deployer);
    expect(unpause.result).toBeOk(Cl.bool(true));

    const apply = simnet.callPublicFn(
      CONTRACT,
      "apply-loan",
      [Cl.uint(1_000_000n), Cl.uint(MIN_DURATION)],
      borrower,
    );
    expect(apply.result).toBeOk(Cl.uint(1_000_000n));
  });
});
