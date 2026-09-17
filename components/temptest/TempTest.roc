import TestNet

## TEMP TESTING namespace — NOT part of the platform's real surface. It bundles
## the throwaway test scaffolding (the in-process HTTP test server the http
## examples talk to, and a signal that interrupts a blocked socket call) under
## one clearly-named module, so it doesn't sit in
## `exposes` looking like basic-cli API. Forwards to the internal `testnet`
## interface. To be replaced when a real http serving API is built.
TempTest :: [].{
	start_test_server! : {} => {}
	start_test_server! = |_| TestNet.start_test_server!({})

	## Signal the calling thread once, `ms` from now, under a counting SIGUSR1
	## handler installed with SA_RESTART exactly when `restart` is true.
	interrupt_after! : U64, Bool => {}
	interrupt_after! = |ms, restart| TestNet.interrupt_after!(ms, restart)

	## SIGUSR1 deliveries since the last call; resets the count.
	take_interrupts! : {} => U64
	take_interrupts! = |_| TestNet.take_interrupts!({})
}
