package main

import (
	"context"
	"insta-dm/core/internal/instagram"
	"insta-dm/core/internal/wire"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	server := wire.New(os.Stdout)
	backend := instagram.New(ctx, server)
	defer backend.Close()
	if err := server.Run(ctx, os.Stdin, backend); err != nil && ctx.Err() == nil {
		// Request bodies, credentials and upstream responses must never be logged.
		_, _ = os.Stderr.WriteString("insta-core: pipe closed or invalid frame size\n")
	}
}
