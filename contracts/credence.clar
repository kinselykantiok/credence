;; ==========================
;; Uncollateralized Loans Protocol
;; Participants: Borrowers, Backers, LPs, Auditors
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

;; Constants for validation
(define-constant MAX_LOAN_AMOUNT u1000000000000) ;; 1M STX in microSTX
(define-constant MIN_LOAN_AMOUNT u1000000) ;; 1 STX in microSTX
(define-constant MAX_DURATION u52560) ;; ~1 year in blocks
(define-constant MIN_DURATION u144) ;; ~1 day in blocks

(define-data-var admin principal tx-sender)

;; Loan struct
(define-map loans
  principal
  {
    amount: uint,
    duration: uint,
    request-time: uint,
    approved: bool,
    disbursed: bool,
    repaid: bool,
    due-time: uint
  }
)

;; Backers - simplified key structure
(define-map backers
  {borrower: principal, backer: principal}
  {
    stake: uint
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

;; Liquidity Pool
(define-data-var pool-balance uint u0)
(define-map lps
  principal
  {
    deposit: uint
  }
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

;; === PARTICIPANT FUNCTIONS ===

;; Borrower applies for a loan
(define-public (apply-loan (amount uint) (duration uint))
  (begin
    ;; Input validation
    (asserts! (is-valid-amount amount) (err ERR_INVALID_AMOUNT))
    (asserts! (is-valid-duration duration) (err ERR_INVALID_DURATION))
    (asserts! (is-valid-principal tx-sender) (err ERR_INVALID_PRINCIPAL))
    
    (map-set loans
      tx-sender
      {
        amount: amount,
        duration: duration,
        request-time: stacks-block-height,
        approved: false,
        disbursed: false,
        repaid: false,
        due-time: (+ stacks-block-height duration)
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
    (ok true)
  )
)

;; Backer supports a borrower
(define-public (back-borrower (borrower principal) (stake uint))
  (begin
    ;; Input validation
    (asserts! (is-valid-principal borrower) (err ERR_INVALID_PRINCIPAL))
    (asserts! (is-valid-stake stake) (err ERR_INVALID_AMOUNT))
    (asserts! (not (is-eq borrower tx-sender)) (err ERR_UNAUTHORIZED))
    (asserts! (is-none (map-get? backers {borrower: borrower, backer: tx-sender})) (err ERR_ALREADY_BACKED))
    
    (try! (stx-transfer? stake tx-sender (as-contract tx-sender)))
    (map-set backers
      {borrower: borrower, backer: tx-sender}
      { stake: stake }
    )
    (ok true)
  )
)

;; Auditor approves/rejects borrower
(define-public (audit-borrower (borrower principal) (approve bool))
  (begin
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

;; LP deposits liquidity
(define-public (deposit-liquidity (amount uint))
  (begin
    ;; Input validation
    (asserts! (is-valid-stake amount) (err ERR_INVALID_AMOUNT))
    (asserts! (is-valid-principal tx-sender) (err ERR_INVALID_PRINCIPAL))
    
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set pool-balance (+ (var-get pool-balance) amount))
    (let ((prev (default-to u0 (get deposit (map-get? lps tx-sender)))))
      (map-set lps
        tx-sender
        { deposit: (+ prev amount) }
      )
    )
    (ok true)
  )
)

;; LP withdraws liquidity
(define-public (withdraw-liquidity (amount uint))
  (let ((user-deposit (map-get? lps tx-sender)))
    ;; Input validation
    (asserts! (> amount u0) (err ERR_INVALID_AMOUNT))
    (asserts! (is-valid-principal tx-sender) (err ERR_INVALID_PRINCIPAL))
    
    (match user-deposit lp
      (begin
        (asserts! (>= (get deposit lp) amount) (err ERR_INSUFFICIENT))
        (asserts! (>= (var-get pool-balance) amount) (err ERR_INSUFFICIENT))
        (map-set lps
          tx-sender
          { deposit: (- (get deposit lp) amount) }
        )
        (var-set pool-balance (- (var-get pool-balance) amount))
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        (ok true)
      )
      (err ERR_NOT_FOUND)
    )
  )
)

;; Admin disburses loan if approved
(define-public (disburse-loan (borrower principal))
  (begin
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
              {
                amount: (get amount l),
                duration: (get duration l),
                request-time: (get request-time l),
                approved: true,
                disbursed: true,
                repaid: false,
                due-time: (get due-time l)
              }
            )

            (var-set pool-balance (- (var-get pool-balance) (get amount l)))
            (ok true)
          )
        )
        (err ERR_NOT_FOUND)
      )
    )
  )
)

;; Borrower repays loan
(define-public (repay-loan)
  (let ((loan (map-get? loans tx-sender)))
    ;; Input validation
    (asserts! (is-valid-principal tx-sender) (err ERR_INVALID_PRINCIPAL))
    
    (match loan l
      (begin
        (asserts! (get disbursed l) (err ERR_NOT_APPROVED))
        (asserts! (not (get repaid l)) (err ERR_ALREADY_PAID))
        (try! (stx-transfer? (get amount l) tx-sender (as-contract tx-sender)))
        (var-set pool-balance (+ (var-get pool-balance) (get amount l)))
        (map-set loans
          tx-sender
          {
            amount: (get amount l),
            duration: (get duration l),
            request-time: (get request-time l),
            approved: true,
            disbursed: true,
            repaid: true,
            due-time: (get due-time l)
          }
        )
        (ok true)
      )
      (err ERR_NOT_FOUND)
    )
  )
)

;; Admin slashes a specific backer if borrower defaults
(define-public (slash-backer (borrower principal) (backer principal))
  (begin
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

;; === Read-only functions ===

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

(define-read-only (get-lp-deposit (provider principal))
  (if (is-valid-principal provider)
    (map-get? lps provider)
    none
  )
)

(define-read-only (get-admin)
  (var-get admin)
)

;; Admin function to change admin
(define-public (set-admin (new-admin principal))
  (begin
    ;; Input validation
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_UNAUTHORIZED))
    (asserts! (is-valid-principal new-admin) (err ERR_INVALID_PRINCIPAL))
    (asserts! (not (is-eq new-admin tx-sender)) (err ERR_UNAUTHORIZED))
    
    (var-set admin new-admin)
    (ok true)
  )
)