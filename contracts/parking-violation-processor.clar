;; Parking Violation Processor Smart Contract
;; Manages parking violations with fine collection and automated appeals

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-paid (err u102))
(define-constant err-already-appealed (err u103))
(define-constant err-invalid-status (err u104))
(define-constant err-unauthorized (err u105))
(define-constant err-invalid-amount (err u106))
(define-constant err-appeal-deadline-passed (err u107))

;; Violation statuses
(define-constant status-issued u1)
(define-constant status-paid u2)
(define-constant status-appealed u3)
(define-constant status-appeal-approved u4)
(define-constant status-appeal-denied u5)
(define-constant status-dismissed u6)

;; Appeal deadline in blocks (approximately 30 days)
(define-constant appeal-deadline u4320)

;; Data Variables
(define-data-var violation-counter uint u0)
(define-data-var total-revenue uint u0)
(define-data-var total-violations uint u0)
(define-data-var total-appeals uint u0)

;; Data Maps
(define-map violations
  { violation-id: uint }
  {
    vehicle-plate: (string-ascii 20),
    violation-type: (string-ascii 50),
    location: (string-ascii 100),
    fine-amount: uint,
    issue-block: uint,
    status: uint,
    issuing-officer: principal,
    payment-block: (optional uint),
    appeal-block: (optional uint),
    appeal-reason: (optional (string-utf8 500)),
    appeal-decision: (optional (string-utf8 500))
  }
)

(define-map authorized-officers principal bool)

(define-map vehicle-violations
  { vehicle-plate: (string-ascii 20) }
  { violation-count: uint, total-fines: uint }
)

(define-map officer-stats
  { officer: principal }
  { violations-issued: uint, total-collected: uint }
)

;; Authorization Functions
(define-public (add-authorized-officer (officer principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (ok (map-set authorized-officers officer true))
  )
)

(define-public (remove-authorized-officer (officer principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (ok (map-delete authorized-officers officer))
  )
)

(define-read-only (is-authorized-officer (officer principal))
  (default-to false (map-get? authorized-officers officer))
)

;; Core Functions
(define-public (issue-violation 
  (vehicle-plate (string-ascii 20))
  (violation-type (string-ascii 50))
  (location (string-ascii 100))
  (fine-amount uint))
  (let
    (
      (violation-id (+ (var-get violation-counter) u1))
      (current-vehicle-stats (default-to 
        { violation-count: u0, total-fines: u0 }
        (map-get? vehicle-violations { vehicle-plate: vehicle-plate })))
      (current-officer-stats (default-to
        { violations-issued: u0, total-collected: u0 }
        (map-get? officer-stats { officer: tx-sender })))
    )
    (asserts! (or (is-eq tx-sender contract-owner) (is-authorized-officer tx-sender)) err-unauthorized)
    (asserts! (> fine-amount u0) err-invalid-amount)
    
    (map-set violations
      { violation-id: violation-id }
      {
        vehicle-plate: vehicle-plate,
        violation-type: violation-type,
        location: location,
        fine-amount: fine-amount,
        issue-block: stacks-block-height,
        status: status-issued,
        issuing-officer: tx-sender,
        payment-block: none,
        appeal-block: none,
        appeal-reason: none,
        appeal-decision: none
      }
    )
    
    (map-set vehicle-violations
      { vehicle-plate: vehicle-plate }
      {
        violation-count: (+ (get violation-count current-vehicle-stats) u1),
        total-fines: (+ (get total-fines current-vehicle-stats) fine-amount)
      }
    )
    
    (map-set officer-stats
      { officer: tx-sender }
      {
        violations-issued: (+ (get violations-issued current-officer-stats) u1),
        total-collected: (get total-collected current-officer-stats)
      }
    )
    
    (var-set violation-counter violation-id)
    (var-set total-violations (+ (var-get total-violations) u1))
    (ok violation-id)
  )
)

(define-public (pay-violation (violation-id uint))
  (let
    (
      (violation (unwrap! (map-get? violations { violation-id: violation-id }) err-not-found))
      (current-officer-stats (default-to
        { violations-issued: u0, total-collected: u0 }
        (map-get? officer-stats { officer: (get issuing-officer violation) })))
    )
    (asserts! (is-eq (get status violation) status-issued) err-invalid-status)
    
    (map-set violations
      { violation-id: violation-id }
      (merge violation {
        status: status-paid,
        payment-block: (some stacks-block-height)
      })
    )
    
    (map-set officer-stats
      { officer: (get issuing-officer violation) }
      {
        violations-issued: (get violations-issued current-officer-stats),
        total-collected: (+ (get total-collected current-officer-stats) (get fine-amount violation))
      }
    )
    
    (var-set total-revenue (+ (var-get total-revenue) (get fine-amount violation)))
    (ok true)
  )
)

(define-public (submit-appeal (violation-id uint) (reason (string-utf8 500)))
  (let
    (
      (violation (unwrap! (map-get? violations { violation-id: violation-id }) err-not-found))
      (blocks-since-issue (- stacks-block-height (get issue-block violation)))
    )
    (asserts! (is-eq (get status violation) status-issued) err-invalid-status)
    (asserts! (<= blocks-since-issue appeal-deadline) err-appeal-deadline-passed)
    
    (map-set violations
      { violation-id: violation-id }
      (merge violation {
        status: status-appealed,
        appeal-block: (some stacks-block-height),
        appeal-reason: (some reason)
      })
    )
    
    (var-set total-appeals (+ (var-get total-appeals) u1))
    (ok true)
  )
)

(define-public (review-appeal (violation-id uint) (approved bool) (decision (string-utf8 500)))
  (let
    (
      (violation (unwrap! (map-get? violations { violation-id: violation-id }) err-not-found))
    )
    (asserts! (or (is-eq tx-sender contract-owner) (is-authorized-officer tx-sender)) err-unauthorized)
    (asserts! (is-eq (get status violation) status-appealed) err-invalid-status)
    
    (map-set violations
      { violation-id: violation-id }
      (merge violation {
        status: (if approved status-appeal-approved status-appeal-denied),
        appeal-decision: (some decision)
      })
    )
    
    (ok true)
  )
)

(define-public (dismiss-violation (violation-id uint))
  (let
    (
      (violation (unwrap! (map-get? violations { violation-id: violation-id }) err-not-found))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    (map-set violations
      { violation-id: violation-id }
      (merge violation { status: status-dismissed })
    )
    
    (ok true)
  )
)

;; Read-Only Functions
(define-read-only (get-violation (violation-id uint))
  (map-get? violations { violation-id: violation-id })
)

(define-read-only (get-vehicle-stats (vehicle-plate (string-ascii 20)))
  (map-get? vehicle-violations { vehicle-plate: vehicle-plate })
)

(define-read-only (get-officer-stats (officer principal))
  (map-get? officer-stats { officer: officer })
)

(define-read-only (get-total-violations)
  (ok (var-get total-violations))
)

(define-read-only (get-total-revenue)
  (ok (var-get total-revenue))
)

(define-read-only (get-total-appeals)
  (ok (var-get total-appeals))
)

(define-read-only (get-violation-counter)
  (ok (var-get violation-counter))
)

(define-read-only (is-violation-paid (violation-id uint))
  (match (map-get? violations { violation-id: violation-id })
    violation (ok (is-eq (get status violation) status-paid))
    err-not-found
  )
)

(define-read-only (is-violation-appealed (violation-id uint))
  (match (map-get? violations { violation-id: violation-id })
    violation (ok (or 
      (is-eq (get status violation) status-appealed)
      (is-eq (get status violation) status-appeal-approved)
      (is-eq (get status violation) status-appeal-denied)
    ))
    err-not-found
  )
)

(define-read-only (can-appeal-violation (violation-id uint))
  (match (map-get? violations { violation-id: violation-id })
    violation 
      (ok (and
        (is-eq (get status violation) status-issued)
        (<= (- stacks-block-height (get issue-block violation)) appeal-deadline)
      ))
    err-not-found
  )
)

;; Initialize contract owner as authorized officer
(map-set authorized-officers contract-owner true)
