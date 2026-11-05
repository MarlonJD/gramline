package bloks

import (
	"context"
	"fmt"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/loginerrors"
)

type loginTimer struct {
	next      time.Time
	interval  time.Duration
	repeating bool
	callback  func() error
}

func (b *Browser) startTimer(name string, interval time.Duration, repeating bool, callback func() error) error {
	if callback == nil {
		return fmt.Errorf("login timer has no callback")
	}
	if b.timers == nil {
		b.timers = map[string]*loginTimer{}
	}
	interval = max(interval, 0)
	b.timers[name] = &loginTimer{next: time.Now().Add(interval), interval: interval, repeating: repeating, callback: callback}
	return nil
}

// Run callbacks serially with the login interpreter. Delivery checks, approval
// polls and one-shot timers can coexist without racing browser state or RPCs.
func (b *Browser) runNextTimer(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	var name string
	var next *loginTimer
	for key, timer := range b.timers {
		if next == nil || timer.next.Before(next.next) {
			name, next = key, timer
		}
	}
	if next == nil {
		return loginerrors.AFADStopped
	}
	wait := time.NewTimer(max(time.Until(next.next), 0))
	defer wait.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-wait.C:
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if !next.repeating {
		delete(b.timers, name)
	}
	if err := next.callback(); err != nil {
		return err
	}
	// The callback may cancel or replace its own timer.
	if b.timers[name] == next {
		next.next = time.Now().Add(next.interval)
	}
	return nil
}
