//go:build !linux

package state

// Directory fsync is not supported by the Windows development filesystem.
func syncDirectory(string) error { return nil }
