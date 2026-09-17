## roc:testnet — TEST-ONLY. Starts the in-process HTTP test server (:9000)
## the basic-cli http examples expect (basic-cli runs ci/rust_http_server; here
## it is a host thread). Binds synchronously, then serves on a background thread.
TestNet :: [].{
	start_test_server! : {} => {}
	## Installs a counting SIGUSR1 handler (with SA_RESTART when the Bool is
	## true) and signals the calling thread once, the given milliseconds later.
	interrupt_after! : U64, Bool => {}
	## SIGUSR1 deliveries since the last call; resets the count.
	take_interrupts! : {} => U64
}
