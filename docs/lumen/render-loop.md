# Render loop: last queued frame

The frame selection loops (`Renderer.swift`, `RealityKitClientSystem.swift`) copy `EventHandler.lastQueuedFrame` once per iteration under `frameQueueLock` and use only the copy, because `EventHandler.stop()` clears it on another thread and a nil check followed by `!` crashed ("Unexpectedly found nil") when streaming stopped mid-selection; the retry rule is `FramePacing.shouldRetry`.
