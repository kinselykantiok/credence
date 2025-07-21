# Credence: Uncollateralized Loans Protocol

This Clarity smart contract implements an **uncollateralized loans protocol** for the Stacks blockchain. It coordinates four participant roles: **Borrowers**, **Backers**, **Liquidity Providers (LPs)**, and **Auditors**. The protocol enables trustless lending and borrowing without collateral, using auditor approvals and backer stakes for risk mitigation.

---

## Features

- **Borrowers** can apply for loans and repay them.
- **Backers** stake funds to support borrowers.
- **Auditors** vote to approve or reject loan requests.
- **Liquidity Providers (LPs)** deposit and withdraw liquidity for the loan pool.
- **Admin** manages loan disbursement, slashing backers on default, and can transfer admin rights.

---

## Data Structures

- **loans**: Maps borrower to loan details (amount, duration, approval, disbursement, repayment, due time).
- **backers**: Tracks backer stakes for each borrower.
- **audits**: Records auditor votes for each borrower.
- **vote-counts**: Tracks yes/no votes from auditors per borrower.
- **pool-balance**: Total liquidity available for loans.
- **lps**: Tracks each LP’s deposit.
- **admin**: Stores the admin principal.

---

## Core Functions

### Borrower Actions

- `apply-loan(amount, duration)`: Request a loan.
- `repay-loan()`: Repay a disbursed loan.

### Backer Actions

- `back-borrower(borrower, stake)`: Stake funds to support a borrower.

### Auditor Actions

- `audit-borrower(borrower, approve)`: Vote to approve or reject a borrower’s loan request.

### LP Actions

- `deposit-liquidity(amount)`: Deposit funds into the pool.
- `withdraw-liquidity(amount)`: Withdraw funds from the pool.

### Admin Actions

- `disburse-loan(borrower)`: Disburse loan if approved by at least 2 auditors.
- `slash-backer(borrower, backer)`: Remove a backer’s stake if borrower defaults.
- `set-admin(new-admin)`: Transfer admin rights.

### Read-only Functions

- `get-loan(user)`: Get loan details for a user.
- `get-backer-stake(borrower, backer)`: Get backer’s stake for a borrower.
- `get-audit-vote(borrower, auditor)`: Get auditor’s vote for a borrower.
- `get-vote-count(borrower)`: Get auditor vote counts for a borrower.
- `get-pool-balance()`: Get current pool balance.
- `get-lp-deposit(provider)`: Get LP’s deposit.
- `get-admin()`: Get current admin principal.

---

## Validation & Error Handling

- Strict input validation for principals, amounts, durations, and authorization.
- Error codes for unauthorized actions, invalid inputs, insufficient funds, and other failure cases.

---

## Usage Example

1. **Borrower** applies for a loan.
2. **Backers** stake to support the borrower.
3. **Auditors** vote to approve/reject the loan.
4. **Admin** disburses the loan if approved.
5. **Borrower** repays the loan.
6. **Admin** slashes backers if borrower defaults.

---

## Deployment

Deploy the contract to the Stacks blockchain using the Clarity language. Ensure the admin principal is set correctly.

---

## License

This contract is provided for educational and experimental purposes. Please review and audit before deploying in production.

---

## Contact

For questions or contributions, open an issue or pull request in the repository.
