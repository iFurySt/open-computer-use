# Guardian cleanup after a completed lease

## Goal

Fix [issue #157](https://github.com/iFurySt/open-computer-use/issues/157):
an authenticated Guardian must finish cleanup after a normal lease completion,
without granting new actions or admitting a new lease before release.

## Mechanism

The coordinator retains `connectionOwner` for cleanup. The state machine clears
its active owner when it returns to idle. A stopped Guardian report must not
call `machine.end` with the retained cleanup identity after that reset.

## Work and evidence

- [x] Reproduce `clientUnauthorized` through the real coordinator API.
- [x] Use the state machine's active owner in the stopped-report branch.
- [x] Extend the existing release-acknowledgement regression.
- [x] Verify cleanup and next-lease admission through the real library API.
- [x] Run the affected XCTest suite in an environment providing XCTest.
- [ ] Verify the signed system components on an isolated locked desktop.

The local Command Line Tools installation cannot resolve XCTest. A standalone
Swift executable importing the actual library fails before the fix and passes
after it. [macOS CI](https://github.com/joyleiyc/open-computer-use/actions/runs/42342567222)
also confirms the new XCTest fails on the original coordinator with
`clientUnauthorized`, while all 126 Locked Use tests pass with the fix under
Xcode 26.6 / Swift 6.3.3. The local harness creates no GUI session and changes
no system authentication state; CI does not install the privileged components.

## Boundaries

Preserve peer/lease checks, permit revocation, action drainage, lock observation
and guard acknowledgements. Do not install unsigned development components.
The offline proof does not establish signed desktop recovery or remote-input
compatibility.
