;; ==========================
;; Enhanced Uncollateralized Loans Protocol
;; Participants: Borrowers, Backers, LPs, Auditors
;; Features: Interest Rates, Security Controls, Economic Incentives
;; ==========================

;; Error codes
(define-constant ERR_UNAUTHORIZED u100)
(define-constant ERR_NOT_FOUND u101)
(define-constant ERR_ALREADY_VOTED u102)
(define-constant ERR_ALREADY_BACKED u103)
(define-constant ERR_NOT_APPROVED u104)
(define-constant ERR_INSUFFICIENT u105)
(define-constant ERR_NOT_DUE u106)
(define-constant ERR_ALREADY_PAID u107)
(define-constant ERR_ALREADY_DISBURSED u108)
(define-constant ERR_INVALID_PRINCIPAL u109)
(define-constant ERR_INVALID_AMOUNT u110)
(define-constant ERR_INVALID_DURATION u111)
(define-constant ERR_CONTRACT_PAUSED u112)
(define-constant ERR_REENTRANCY u113)
(define-constant ERR_RATE_LIMITED u114)
(define-constant ERR_ALREADY_PROCESSED u115)

;; Constants for validation
(define-constant MAX_LOAN_AMOUNT u1000000000000) ;; 1M STX in microSTX
(define-constant MIN_LOAN_AMOUNT u1000000) ;; 1 STX in microSTX
(define-constant MAX_DURATION u52560) ;; ~1 year in blocks
(define-constant MIN_DURATION u144) ;; ~1 day in blocks

;; Interest rate constants (in basis points)
(define-constant BASE_INTEREST_RATE u500) ;; 5%
(define-constant PLATFORM_FEE_RATE u100) ;; 1%
(define-constant BACKER_REWARD_RATE u200) ;; 2%
(define-constant MAX_INTEREST_RATE u2000) ;; 20% max

;; Security constants
(define-constant DAILY_LOAN_LIMIT u3)
(define-constant BLOCKS_PER_DAY u144)

;; Role constants
(define-constant ROLE_ADMIN u1)
(define-constant ROLE_AUDITOR u2)
(define-constant ROLE_EMERGENCY u3)

;; State variables
(define-data-var admin principal tx-sender)
(define-data-var contract-paused bool false)
(define-data-var reentrancy-guard bool false)
(define-data-var base-interest-rate uint BASE_INTEREST_RATE)
(define-data-var platform-fee-rate uint PLATFORM_FEE_RATE)
(define-data-var backer-reward-rate uint BACKER_REWARD_RATE)

;; Enhanced loan struct with interest
(define-map loans
  principal
  {
    amount: uint,
    duration: uint,
    request-time: uint,
    approved: bool,
    disbursed: bool,
    repaid: bool,
    due-time: uint,
    interest-rate: uint,
    total-repayment: uint,
    platform-fee: uint
  }
)

;; Backers - simplified key structure
(define-map backers
  {borrower: principal, backer: principal}
  {
    stake: uint,
    reward-earned: uint
  }
)

;; Auditor votes - simplified key structure
(define-map audits
  {borrower: principal, auditor: principal}
  {
    approved: bool
  }
)

;; Vote count tracking for each borrower
(define-map vote-counts
  principal
  {
    yes-votes: uint,
    no-votes: uint
  }
)

;; Enhanced LP tracking with rewards
(define-data-var pool-balance uint u0)
(define-data-var total-interest-earned uint u0)
(define-map lps
  principal
  {
    deposit: uint,
    rewards-earned: uint,
    last-deposit-block: uint
  }
)

;; Security: Role management
(define-map user-roles
  principal
  { roles: (list 10 uint) }
)

;; Security: Emergency operators
(define-map emergency-operators
  principal
  { authorized: bool }
)

;; Security: Rate limiting
(define-map user-actions
  { user: principal, action: (string-ascii 20) }
  { 
    count: uint,
    last-reset: uint
  }
)

;; Borrower reputation tracking
(define-map borrower-reputation
  principal
  {
    total-loans: uint,
    successful-repayments: uint,
    defaults: uint,
    credit-score: uint
  }
)

;; Add status tracking for withdrawals
(define-map withdrawal-status
  { tx-sender: principal, block: uint }
  { processed: bool }
)

;; === UTILITY FUNCTIONS ===

;; Custom min function since Clarity doesn't have built-in min
(define-private (min-uint (a uint) (b uint))
  (if (<= a b) a b)
)

;; Custom max function for completeness
(define-private (max-uint (a uint) (b uint))
  (if (>= a b) a b)
)

;; === SECURITY FUNCTIONS ===

(define-private (check-reentrancy)
  (begin
    (asserts! (not (var-get reentrancy-guard)) (err ERR_REENTRANCY))
    (var-set reentrancy-guard true)
    (ok true)
  )
)

(define-private (clear-reentrancy)
  (var-set reentrancy-guard false)
)

(define-private (check-pause)
  (begin
    (asserts! (not (var-get contract-paused)) (err ERR_CONTRACT_PAUSED))
    (ok true)
  )
)

(define-private (has-role (user principal) (role uint))
  (match (map-get? user-roles user)
    user-data (is-some (index-of (get roles user-data) role))
    false
  )
)

(define-private (is-emergency-operator (user principal))
  (match (map-get? emergency-operators user)
    operator (get authorized operator)
    false
  )
)

(define-private (check-rate-limit (action (string-ascii 20)) (limit uint))
  (let (
    (current-block stacks-block-height)
    (user-action-key { user: tx-sender, action: action })
    (current-data (default-to { count: u0, last-reset: current-block } 
                              (map-get? user-actions user-action-key)))
  )
    (if (> (- current-block (get last-reset current-data)) BLOCKS_PER_DAY)
      (begin
        (map-set user-actions user-action-key { count: u1, last-reset: current-block })
        (ok true)
      )
      (begin
        (asserts! (< (get count current-data) limit) (err ERR_RATE_LIMITED))
        (map-set user-actions user-action-key 
          { 
            count: (+ (get count current-data) u1), 
            last-reset: (get last-reset current-data) 
          })
        (ok true)
      )
    )
  )
)

;; === INTEREST CALCULATION FUNCTIONS ===

(define-private (calculate-credit-score (borrower principal))
  (match (map-get? borrower-reputation borrower)
    rep (let (
      (success-rate (if (> (get total-loans rep) u0)
                      (/ (* (get successful-repayments rep) u100) (get total-loans rep))
                      u50))
      (default-rate (if (> (get total-loans rep) u0)
                      (/ (* (get defaults rep) u100) (get total-loans rep))
                      u10))
      (base-score (+ (* success-rate u8) u200))
      (penalty (min-uint base-score (* default-rate u20)))
    )
      (- base-score penalty)
    )
    u500 ;; Default score for new borrowers
  )
)

(define-private (calculate-risk-multiplier (credit-score uint))
  (if (> credit-score u700) u100      ;; Low risk: 1x
    (if (> credit-score u500) u150    ;; Medium risk: 1.5x
      u200))                          ;; High risk: 2x
)

(define-private (calculate-interest (amount uint) (duration uint) (credit-score uint))
  (let (
    (risk-multiplier (calculate-risk-multiplier credit-score))
    (adjusted-rate (/ (* (var-get base-interest-rate) risk-multiplier) u100))
    (annual-interest (/ (* amount adjusted-rate) u10000))
    (duration-factor (/ duration u52560)) ;; Convert to yearly fraction
  )
    (/ (* annual-interest duration-factor) u1)
  )
)

(define-private (calculate-platform-fee (total-repayment uint))
  (/ (* total-repayment (var-get platform-fee-rate)) u10000)
)

;; === VALIDATION FUNCTIONS ===

(define-private (is-valid-principal (addr principal))
  (not (is-eq addr 'SP000000000000000000002Q6VF78))
)

(define-private (is-valid-amount (amount uint))
  (and (>= amount MIN_LOAN_AMOUNT) (<= amount MAX_LOAN_AMOUNT))
)

(define-private (is-valid-duration (duration uint))
  (and (>= duration MIN_DURATION) (<= duration MAX_DURATION))
)

(define-private (is-valid-stake (stake uint))
  (and (> stake u0) (<= stake MAX_LOAN_AMOUNT))
)

;; === ENHANCED PARTICIPANT FUNCTIONS ===

;; Enhanced borrower loan application with interest calculation
(define-public (apply-loan (amount uint) (duration uint))
  (begin
    ;; Security checks
    (try! (check-pause))
    (try! (check-reentrancy))
    (try! (check-rate-limit "apply-loan" DAILY_LOAN_LIMIT))
    
    ;; Input validation
    (asserts! (is-valid-amount amount) (err ERR_INVALID_AMOUNT))
    (asserts! (is-valid-duration duration) (err ERR_INVALID_DURATION))
    (asserts! (is-valid-principal tx-sender) (err ERR_INVALID_PRINCIPAL))
    
    (let (
      (credit-score (calculate-credit-score tx-sender))
      (interest (calculate-interest amount duration credit-score))
      (total-repayment (+ amount interest))
      (platform-fee (calculate-platform-fee total-repayment))
      (risk-multiplier (calculate-risk-multiplier credit-score))
      (final-interest-rate (/ (* (var-get base-interest-rate) risk-multiplier) u100))
    )
      (map-set loans
        tx-sender
        {
          amount: amount,
          duration: duration,
          request-time: stacks-block-height,
          approved: false,
          disbursed: false,
          repaid: false,
          due-time: (+ stacks-block-height duration),
          interest-rate: final-interest-rate,
          total-repayment: total-repayment,
          platform-fee: platform-fee
        }
      )
      ;; Initialize vote count
      (map-set vote-counts
        tx-sender
        {
          yes-votes: u0,
          no-votes: u0
        }
      )
      (clear-reentrancy)
      (ok total-repayment)
    )
  )
)

;; Enhanced backer function with rewards tracking
(define-public (back-borrower (borrower principal) (stake uint))
  (begin
    ;; Security checks
    (try! (check-pause))
    (try! (check-reentrancy))
    
    ;; Input validation
    (asserts! (is-valid-principal borrower) (err ERR_INVALID_PRINCIPAL))
    (asserts! (is-valid-stake stake) (err ERR_INVALID_AMOUNT))
    (asserts! (not (is-eq borrower tx-sender)) (err ERR_UNAUTHORIZED))
    (asserts! (is-none (map-get? backers {borrower: borrower, backer: tx-sender})) (err ERR_ALREADY_BACKED))
    
    (try! (stx-transfer? stake tx-sender (as-contract tx-sender)))
    (map-set backers
      {borrower: borrower, backer: tx-sender}
      { 
        stake: stake,
        reward-earned: u0
      }
    )
    (clear-reentrancy)
    (ok true)
  )
)

;; Enhanced auditor function (unchanged logic but with security)
(define-public (audit-borrower (borrower principal) (approve bool))
  (begin
    ;; Security checks
    (try! (check-pause))
    
    ;; Input validation
    (asserts! (is-valid-principal borrower) (err ERR_INVALID_PRINCIPAL))
    (asserts! (not (is-eq borrower tx-sender)) (err ERR_UNAUTHORIZED))
    (asserts! (is-some (map-get? loans borrower)) (err ERR_NOT_FOUND))
    (asserts! (is-none (map-get? audits {borrower: borrower, auditor: tx-sender})) (err ERR_ALREADY_VOTED))
    
    (map-set audits
      {borrower: borrower, auditor: tx-sender}
      { approved: approve }
    )
    ;; Update vote count
    (let ((current-votes (default-to {yes-votes: u0, no-votes: u0} (map-get? vote-counts borrower))))
      (if approve
        (map-set vote-counts
          borrower
          {
            yes-votes: (+ (get yes-votes current-votes) u1),
            no-votes: (get no-votes current-votes)
          }
        )
        (map-set vote-counts
          borrower
          {
            yes-votes: (get yes-votes current-votes),
            no-votes: (+ (get no-votes current-votes) u1)
          }
        )
      )
    )
    (ok true)
  )
)

;; Enhanced LP deposit with rewards tracking
(define-public (deposit-liquidity (amount uint))
  (begin
    ;; Security checks
    (try! (check-pause))
    (try! (check-reentrancy))
    
    ;; Input validation
    (asserts! (is-valid-stake amount) (err ERR_INVALID_AMOUNT))
    (asserts! (is-valid-principal tx-sender) (err ERR_INVALID_PRINCIPAL))
    
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set pool-balance (+ (var-get pool-balance) amount))
    (let ((prev-deposit (default-to u0 (get deposit (map-get? lps tx-sender))))
          (prev-rewards (default-to u0 (get rewards-earned (map-get? lps tx-sender)))))
      (map-set lps
        tx-sender
        { 
          deposit: (+ prev-deposit amount),
          rewards-earned: prev-rewards,
          last-deposit-block: stacks-block-height
        }
      )
    )
    (clear-reentrancy)
    (ok true)
  )
)

;; FIXED: Enhanced LP withdrawal with proper reentrancy protection and transaction tracking
(define-public (withdraw-liquidity (amount uint))
  (begin
    ;; Security checks FIRST
    (try! (check-pause))
    (try! (check-reentrancy))
    
    ;; Input validation
    (asserts! (> amount u0) (err ERR_INVALID_AMOUNT))
    (asserts! (is-valid-principal tx-sender) (err ERR_INVALID_PRINCIPAL))
    
    ;; Check withdrawal status to prevent double-processing
    (asserts! (is-none (map-get? withdrawal-status 
                        { tx-sender: tx-sender, block: stacks-block-height }))
              (err ERR_ALREADY_PROCESSED))
    
    (let (
      (user-deposit (unwrap! (map-get? lps tx-sender) (err ERR_NOT_FOUND)))
      (recipient contract-caller)
    )
      ;; Validation BEFORE state changes
      (asserts! (>= (get deposit user-deposit) amount) (err ERR_INSUFFICIENT))
      (asserts! (>= (var-get pool-balance) amount) (err ERR_INSUFFICIENT))
      
      ;; State updates BEFORE external call
      (map-set withdrawal-status
        { tx-sender: tx-sender, block: stacks-block-height }
        { processed: true })
      
      (map-set lps tx-sender {
        deposit: (- (get deposit user-deposit) amount),
        rewards-earned: (get rewards-earned user-deposit),
        last-deposit-block: (get last-deposit-block user-deposit)
      })
      
      (var-set pool-balance (- (var-get pool-balance) amount))
      
      ;; Clear reentrancy guard BEFORE external call
      (clear-reentrancy)
      
      ;; External call LAST
      (as-contract (stx-transfer? amount tx-sender recipient))
    )
  )
)

;; Enhanced loan disbursement (admin only)
(define-public (disburse-loan (borrower principal))
  (begin
    ;; Security checks
    (try! (check-pause))
    (try! (check-reentrancy))
    
    ;; Input validation
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_UNAUTHORIZED))
    (asserts! (is-valid-principal borrower) (err ERR_INVALID_PRINCIPAL))
    
    (let ((loan (map-get? loans borrower)))
      (match loan l
        (begin
          (asserts! (not (get disbursed l)) (err ERR_ALREADY_DISBURSED))
          
          ;; Get vote count
          (let ((votes (default-to {yes-votes: u0, no-votes: u0} (map-get? vote-counts borrower))))
            ;; Require at least 2 auditor approvals
            (asserts! (>= (get yes-votes votes) u2) (err ERR_NOT_APPROVED))

            ;; Disburse funds
            (asserts! (>= (var-get pool-balance) (get amount l)) (err ERR_INSUFFICIENT))
            (try! (as-contract (stx-transfer? (get amount l) tx-sender borrower)))

            ;; Mark as approved and disbursed
            (map-set loans
              borrower
              (merge l { approved: true, disbursed: true })
            )

            (var-set pool-balance (- (var-get pool-balance) (get amount l)))
            (clear-reentrancy)
            (ok true)
          )
        )
        (err ERR_NOT_FOUND)
      )
    )
  )
)

;; Enhanced repayment with interest and fee distribution
(define-public (repay-loan)
  (let ((loan (map-get? loans tx-sender)))
    ;; Security checks
    (try! (check-pause))
    (try! (check-reentrancy))
    
    ;; Input validation
    (asserts! (is-valid-principal tx-sender) (err ERR_INVALID_PRINCIPAL))
    
    (match loan l
      (begin
        (asserts! (get disbursed l) (err ERR_NOT_APPROVED))
        (asserts! (not (get repaid l)) (err ERR_ALREADY_PAID))
        
        (let (
          (total-repayment (get total-repayment l))
          (platform-fee (get platform-fee l))
          (net-amount (- total-repayment platform-fee))
          (on-time (<= stacks-block-height (get due-time l)))
        )
          ;; Transfer total repayment
          (try! (stx-transfer? total-repayment tx-sender (as-contract tx-sender)))
          
          ;; Add net amount back to pool (after platform fee)
          (var-set pool-balance (+ (var-get pool-balance) net-amount))
          (var-set total-interest-earned (+ (var-get total-interest-earned) (- total-repayment (get amount l))))
          
          ;; Update borrower reputation
          (let ((current-rep (default-to 
                { total-loans: u0, successful-repayments: u0, defaults: u0, credit-score: u500 }
                (map-get? borrower-reputation tx-sender))))
            (map-set borrower-reputation tx-sender
              {
                total-loans: (+ (get total-loans current-rep) u1),
                successful-repayments: (if on-time (+ (get successful-repayments current-rep) u1) (get successful-repayments current-rep)),
                defaults: (if on-time (get defaults current-rep) (+ (get defaults current-rep) u1)),
                credit-score: (calculate-credit-score tx-sender)
              }
            )
          )
          
          ;; Mark as repaid
          (map-set loans
            tx-sender
            (merge l { repaid: true })
          )
          (clear-reentrancy)
          (ok on-time)
        )
      )
      (err ERR_NOT_FOUND)
    )
  )
)

;; Enhanced slashing with reputation update
(define-public (slash-backer (borrower principal) (backer principal))
  (begin
    ;; Security checks
    (try! (check-pause))
    
    ;; Input validation
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_UNAUTHORIZED))
    (asserts! (is-valid-principal borrower) (err ERR_INVALID_PRINCIPAL))
    (asserts! (is-valid-principal backer) (err ERR_INVALID_PRINCIPAL))
    (asserts! (not (is-eq borrower backer)) (err ERR_UNAUTHORIZED))
    
    (let ((loan (map-get? loans borrower)))
      (match loan l
        (begin
          (asserts! (get disbursed l) (err ERR_NOT_APPROVED))
          (asserts! (not (get repaid l)) (err ERR_ALREADY_PAID))
          (asserts! (> stacks-block-height (get due-time l)) (err ERR_NOT_DUE))

          ;; Update borrower reputation for default
          (let ((current-rep (default-to 
                { total-loans: u0, successful-repayments: u0, defaults: u0, credit-score: u500 }
                (map-get? borrower-reputation borrower))))
            (map-set borrower-reputation borrower
              {
                total-loans: (+ (get total-loans current-rep) u1),
                successful-repayments: (get successful-repayments current-rep),
                defaults: (+ (get defaults current-rep) u1),
                credit-score: (calculate-credit-score borrower)
              }
            )
          )

          ;; Remove the specific backer (funds retained in contract)
          (let ((backer-info (map-get? backers {borrower: borrower, backer: backer})))
            (match backer-info info
              (begin
                (map-delete backers {borrower: borrower, backer: backer})
                (ok true)
              )
              (err ERR_NOT_FOUND)
            )
          )
        )
        (err ERR_NOT_FOUND)
      )
    )
  )
)

;; === SECURITY ADMIN FUNCTIONS ===

(define-public (emergency-pause)
  (begin
    (asserts! (or (is-emergency-operator tx-sender) (is-eq tx-sender (var-get admin))) (err ERR_UNAUTHORIZED))
    (var-set contract-paused true)
    (ok true)
  )
)

(define-public (emergency-unpause)
  (begin
    (asserts! (or (is-emergency-operator tx-sender) (is-eq tx-sender (var-get admin))) (err ERR_UNAUTHORIZED))
    (var-set contract-paused false)
    (ok true)
  )
)

(define-public (add-emergency-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_UNAUTHORIZED))
    (asserts! (is-valid-principal operator) (err ERR_INVALID_PRINCIPAL))
    (map-set emergency-operators operator { authorized: true })
    (ok true)
  )
)

(define-public (remove-emergency-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_UNAUTHORIZED))
    (asserts! (is-some (map-get? emergency-operators operator)) (err ERR_NOT_FOUND))
    (map-set emergency-operators operator { authorized: false })
    (ok true)
  )
)

;; === PARAMETER ADJUSTMENT FUNCTIONS ===

(define-public (set-base-interest-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_UNAUTHORIZED))
    (asserts! (<= new-rate MAX_INTEREST_RATE) (err ERR_INVALID_AMOUNT))
    (var-set base-interest-rate new-rate)
    (ok true)
  )
)

(define-public (set-platform-fee-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_UNAUTHORIZED))
    (asserts! (<= new-rate u1000) (err ERR_INVALID_AMOUNT)) ;; Max 10%
    (var-set platform-fee-rate new-rate)
    (ok true)
  )
)

;; === ENHANCED READ-ONLY FUNCTIONS ===

(define-read-only (get-loan (user principal))
  (if (is-valid-principal user)
    (map-get? loans user)
    none
  )
)

(define-read-only (get-backer-stake (borrower principal) (backer principal))
  (if (and (is-valid-principal borrower) (is-valid-principal backer))
    (map-get? backers {borrower: borrower, backer: backer})
    none
  )
)

(define-read-only (get-audit-vote (borrower principal) (auditor principal))
  (if (and (is-valid-principal borrower) (is-valid-principal auditor))
    (map-get? audits {borrower: borrower, auditor: auditor})
    none
  )
)

(define-read-only (get-vote-count (borrower principal))
  (if (is-valid-principal borrower)
    (map-get? vote-counts borrower)
    none
  )
)

(define-read-only (get-pool-balance)
  (var-get pool-balance)
)

(define-read-only (get-total-interest-earned)
  (var-get total-interest-earned)
)

(define-read-only (get-lp-deposit (provider principal))
  (if (is-valid-principal provider)
    (map-get? lps provider)
    none
  )
)

(define-read-only (get-borrower-reputation (borrower principal))
  (if (is-valid-principal borrower)
    (map-get? borrower-reputation borrower)
    none
  )
)

(define-read-only (get-credit-score (borrower principal))
  (if (is-valid-principal borrower)
    (some (calculate-credit-score borrower))
    none
  )
)

(define-read-only (get-contract-status)
  {
    paused: (var-get contract-paused),
    admin: (var-get admin),
    base-interest-rate: (var-get base-interest-rate),
    platform-fee-rate: (var-get platform-fee-rate),
    pool-balance: (var-get pool-balance),
    total-interest-earned: (var-get total-interest-earned)
  }
)

(define-read-only (get-admin)
  (var-get admin)
)

(define-read-only (is-emergency-operator-check (operator principal))
  (is-emergency-operator operator)
)

;; New read-only function to check withdrawal status
(define-read-only (get-withdrawal-status (user principal) (block uint))
  (map-get? withdrawal-status { tx-sender: user, block: block })
)

;; === ADMIN FUNCTIONS ===

(define-public (set-admin (new-admin principal))
  (begin
    ;; Input validation
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_UNAUTHORIZED))
    (asserts! (is-valid-principal new-admin) (err ERR_INVALID_PRINCIPAL))
    (asserts! (not (is-eq new-admin tx-sender)) (err ERR_UNAUTHORIZED))
    
 
