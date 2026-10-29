package nodehost

import (
	"errors"
	"time"
)

func (h *host) localNow() (time.Time, error) {
	zone := h.opts.Config.BusinessTimezone
	if zone == "" {
		return h.opts.Now().In(time.Local), nil
	}
	location, err := time.LoadLocation(zone)
	if err != nil {
		return time.Time{}, errors.New("invalid business timezone")
	}
	return h.opts.Now().In(location), nil
}

func resetDate(year int, month time.Month, day int, location *time.Location) time.Time {
	last := time.Date(year, month+1, 0, 0, 0, 0, 0, location).Day()
	if day == 32 || day > last {
		day = last
	}
	return time.Date(year, month, day, 0, 0, 0, 0, location)
}

func latestReset(now time.Time, day int) time.Time {
	due := resetDate(now.Year(), now.Month(), day, now.Location())
	if due.After(now) {
		due = resetDate(now.Year(), now.Month()-1, day, now.Location())
	}
	return due
}

func (h *host) dueResets() (map[string]time.Time, error) {
	result := map[string]time.Time{}
	if h.managed() {
		return result, nil
	}
	now, err := h.localNow()
	if err != nil {
		return nil, err
	}
	for name, u := range h.db.Users {
		if name == "admin" || u.ResetDay == 0 {
			continue
		}
		due := latestReset(now, u.ResetDay)
		anchor := u.ResetAnchor
		if anchor == 0 && u.LastReset != "" {
			for _, format := range []string{"2006-01-02", "2006-01"} {
				if parsed, e := time.ParseInLocation(format, u.LastReset, now.Location()); e == nil {
					anchor = parsed.Unix()
					break
				}
			}
		}
		if due.Unix() > anchor {
			result[name] = due
		}
	}
	return result, nil
}

func resetUsage(u *User, when time.Time) error {
	if u.Period >= maxSafe {
		return errors.New("period exhausted")
	}
	u.Up = 0
	u.Down = 0
	u.Manual = 0
	u.Period++
	u.ResetAnchor = when.Unix()
	u.LastReset = when.Format("2006-01-02")
	return nil
}

func (h *host) applyScheduledResets() error {
	due, err := h.dueResets()
	if err != nil {
		return err
	}
	for name, when := range due {
		if err := resetUsage(h.db.Users[name], when); err != nil {
			return err
		}
	}
	return nil
}

func (h *host) nextReset(u *User) (int64, error) {
	if h.managed() || u.ResetDay == 0 {
		return 0, nil
	}
	now, err := h.localNow()
	if err != nil {
		return 0, err
	}
	next := resetDate(now.Year(), now.Month(), u.ResetDay, now.Location())
	if !next.After(now) {
		next = resetDate(now.Year(), now.Month()+1, u.ResetDay, now.Location())
	}
	return next.Unix(), nil
}
