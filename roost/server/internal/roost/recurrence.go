package roost

import (
	"sort"
	"strconv"
	"strings"
	"time"
)

// Go port of the recurrence engine (shared/README.md §5), used by the MCP
// tools to answer "what's on the calendar". Verified against
// shared/fixtures/recurrence.json like the Swift and TypeScript versions.

type localDate struct{ y, m, d int }

func (d localDate) dayNumber() int {
	y := d.y
	if d.m <= 2 {
		y--
	}
	era := y / 400
	if y < 0 && y%400 != 0 {
		era--
	}
	yoe := y - era*400
	mp := (d.m + 9) % 12
	doy := (153*mp+2)/5 + d.d - 1
	doe := yoe*365 + yoe/4 - yoe/100 + doy
	return era*146097 + doe - 719468
}

func dateFromDayNumber(z0 int) localDate {
	z := z0 + 719468
	era := z / 146097
	if z < 0 && z%146097 != 0 {
		era--
	}
	doe := z - era*146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2) / 153
	d := doy - (153*mp+2)/5 + 1
	m := mp + 3
	if mp >= 10 {
		m = mp - 9
	}
	y := yoe + era*400
	if m <= 2 {
		y++
	}
	return localDate{y, m, d}
}

func (d localDate) weekday() int    { return ((d.dayNumber()%7)+11)%7 }
func (d localDate) add(n int) localDate { return dateFromDayNumber(d.dayNumber() + n) }
func (d localDate) less(o localDate) bool { return d.dayNumber() < o.dayNumber() }

func daysIn(y, m int) int { return time.Date(y, time.Month(m)+1, 0, 0, 0, 0, 0, time.UTC).Day() }
func validDate(y, m, d int) bool { return m >= 1 && m <= 12 && d >= 1 && d <= daysIn(y, m) }

type localDT struct {
	date localDate
	hour int
	min  int
}

func (l localDT) minutes() int        { return l.date.dayNumber()*1440 + l.hour*60 + l.min }
func (l localDT) less(o localDT) bool { return l.minutes() < o.minutes() }
func (l localDT) in(loc *time.Location) time.Time {
	return time.Date(l.date.y, time.Month(l.date.m), l.date.d, l.hour, l.min, 0, 0, loc)
}
func toLocalDT(t time.Time, loc *time.Location) localDT {
	t = t.In(loc)
	return localDT{localDate{t.Year(), int(t.Month()), t.Day()}, t.Hour(), t.Minute()}
}
func (l localDT) key(allDay bool) string {
	if allDay {
		return l.date.String()
	}
	return l.date.String() + "T" + pad2(l.hour) + ":" + pad2(l.min)
}
func (d localDate) String() string { return strconv.Itoa(d.y) + "-" + pad2(d.m) + "-" + pad2(d.d) }
func pad2(n int) string {
	if n < 10 {
		return "0" + strconv.Itoa(n)
	}
	return strconv.Itoa(n)
}

var dayCodes = []string{"SU", "MO", "TU", "WE", "TH", "FR", "SA"}

type weekdayNum struct {
	ordinal int // 0 = none
	weekday int
}

type rrule struct {
	freq       string
	interval   int
	count      int // 0 = none
	untilKind  string
	untilDate  localDate
	untilLocal localDT
	untilUTC   time.Time
	byDay      []weekdayNum
	byMonthDay []int
	byMonth    []int
	bySetPos   []int
	wkst       int
}

func parseRRule(s string) *rrule {
	r := &rrule{interval: 1, wkst: 1}
	for _, part := range strings.Split(strings.TrimPrefix(s, "RRULE:"), ";") {
		k, v, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		k, v = strings.ToUpper(k), strings.ToUpper(v)
		switch k {
		case "FREQ":
			switch v {
			case "DAILY", "WEEKLY", "MONTHLY", "YEARLY":
				r.freq = v
			}
		case "INTERVAL":
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				r.interval = n
			}
		case "COUNT":
			if n, err := strconv.Atoi(v); err == nil {
				r.count = n
			}
		case "UNTIL":
			digits := strings.Map(func(c rune) rune {
				if c >= '0' && c <= '9' {
					return c
				}
				return -1
			}, v)
			if len(digits) < 8 {
				continue
			}
			y, _ := strconv.Atoi(digits[:4])
			m, _ := strconv.Atoi(digits[4:6])
			d, _ := strconv.Atoi(digits[6:8])
			date := localDate{y, m, d}
			if !strings.Contains(v, "T") || len(digits) < 12 {
				r.untilKind, r.untilDate = "date", date
				continue
			}
			hh, _ := strconv.Atoi(digits[8:10])
			mm, _ := strconv.Atoi(digits[10:12])
			ss := 0
			if len(digits) >= 14 {
				ss, _ = strconv.Atoi(digits[12:14])
			}
			if strings.HasSuffix(v, "Z") {
				r.untilKind, r.untilUTC = "utc", time.Date(y, time.Month(m), d, hh, mm, ss, 0, time.UTC)
			} else {
				r.untilKind, r.untilLocal = "local", localDT{date, hh, mm}
			}
		case "BYDAY":
			for _, tok := range strings.Split(v, ",") {
				if len(tok) < 2 {
					continue
				}
				wd := indexOf(dayCodes, tok[len(tok)-2:])
				if wd < 0 {
					continue
				}
				ord, _ := strconv.Atoi(tok[:len(tok)-2])
				r.byDay = append(r.byDay, weekdayNum{ord, wd})
			}
		case "BYMONTHDAY":
			for _, x := range strings.Split(v, ",") {
				if n, err := strconv.Atoi(x); err == nil && n != 0 && n >= -31 && n <= 31 {
					r.byMonthDay = append(r.byMonthDay, n)
				}
			}
		case "BYMONTH":
			for _, x := range strings.Split(v, ",") {
				if n, err := strconv.Atoi(x); err == nil && n >= 1 && n <= 12 {
					r.byMonth = append(r.byMonth, n)
				}
			}
		case "BYSETPOS":
			for _, x := range strings.Split(v, ",") {
				if n, err := strconv.Atoi(x); err == nil && n != 0 {
					r.bySetPos = append(r.bySetPos, n)
				}
			}
		case "WKST":
			if i := indexOf(dayCodes, v); i >= 0 {
				r.wkst = i
			}
		}
	}
	if r.freq == "" {
		return nil
	}
	return r
}

func indexOf(list []string, v string) int {
	for i, x := range list {
		if x == v {
			return i
		}
	}
	return -1
}

func containsInt(list []int, v int) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func pickDate(list []localDate, pos int) (localDate, bool) {
	i := pos - 1
	if pos < 0 {
		i = len(list) + pos
	}
	if i < 0 || i >= len(list) {
		return localDate{}, false
	}
	return list[i], true
}

func (r *rrule) monthDays(y, m, defaultDay int) []localDate {
	n := daysIn(y, m)
	var byMD, byD []localDate
	hasMD, hasD := len(r.byMonthDay) > 0, len(r.byDay) > 0
	for _, md := range r.byMonthDay {
		d := md
		if md < 0 {
			d = n + md + 1
		}
		if d >= 1 && d <= n {
			byMD = append(byMD, localDate{y, m, d})
		}
	}
	for _, wd := range r.byDay {
		var all []localDate
		for d := 1; d <= n; d++ {
			if ld := (localDate{y, m, d}); ld.weekday() == wd.weekday {
				all = append(all, ld)
			}
		}
		if wd.ordinal != 0 {
			if p, ok := pickDate(all, wd.ordinal); ok {
				byD = append(byD, p)
			}
		} else {
			byD = append(byD, all...)
		}
	}
	switch {
	case hasMD && hasD:
		var out []localDate
		for _, a := range byMD {
			for _, b := range byD {
				if a == b {
					out = append(out, a)
					break
				}
			}
		}
		return out
	case hasMD:
		return byMD
	case hasD:
		return byD
	}
	if validDate(y, m, defaultDay) {
		return []localDate{{y, m, defaultDay}}
	}
	return nil
}

func (r *rrule) matches(d localDate) bool {
	if len(r.byMonth) > 0 && !containsInt(r.byMonth, d.m) {
		return false
	}
	if len(r.byMonthDay) > 0 {
		n, ok := daysIn(d.y, d.m), false
		for _, md := range r.byMonthDay {
			x := md
			if md < 0 {
				x = n + md + 1
			}
			if x == d.d {
				ok = true
			}
		}
		if !ok {
			return false
		}
	}
	if len(r.byDay) > 0 {
		ok := false
		for _, b := range r.byDay {
			if b.weekday == d.weekday() {
				ok = true
			}
		}
		if !ok {
			return false
		}
	}
	return true
}

func (r *rrule) candidates(period int, start localDT) []localDate {
	s := start.date
	var out []localDate
	switch r.freq {
	case "DAILY":
		if d := s.add(period * r.interval); r.matches(d) {
			out = []localDate{d}
		}
	case "WEEKLY":
		offset := (s.weekday() - r.wkst + 7) % 7
		weekStart := s.add(-offset + period*r.interval*7)
		days := []int{s.weekday()}
		if len(r.byDay) > 0 {
			days = nil
			for _, b := range r.byDay {
				days = append(days, b.weekday)
			}
		}
		for i := 0; i < 7; i++ {
			d := weekStart.add(i)
			if containsInt(days, d.weekday()) && (len(r.byMonth) == 0 || containsInt(r.byMonth, d.m)) {
				out = append(out, d)
			}
		}
	case "MONTHLY":
		total := s.y*12 + (s.m - 1) + period*r.interval
		y, m := total/12, total%12+1
		if len(r.byMonth) > 0 && !containsInt(r.byMonth, m) {
			break
		}
		out = r.monthDays(y, m, s.d)
	case "YEARLY":
		y := s.y + period*r.interval
		hasOrd := false
		for _, b := range r.byDay {
			if b.ordinal != 0 {
				hasOrd = true
			}
		}
		if hasOrd && len(r.byMonth) == 0 && len(r.byMonthDay) == 0 {
			for _, wd := range r.byDay {
				var all []localDate
				for m := 1; m <= 12; m++ {
					for d := 1; d <= daysIn(y, m); d++ {
						if ld := (localDate{y, m, d}); ld.weekday() == wd.weekday {
							all = append(all, ld)
						}
					}
				}
				if wd.ordinal != 0 {
					if p, ok := pickDate(all, wd.ordinal); ok {
						out = append(out, p)
					}
				} else {
					out = append(out, all...)
				}
			}
		} else {
			months := r.byMonth
			if len(months) == 0 {
				months = []int{s.m}
			}
			for _, m := range months {
				if len(r.byMonthDay) == 0 && len(r.byDay) == 0 {
					if validDate(y, m, s.d) {
						out = append(out, localDate{y, m, s.d})
					}
				} else {
					out = append(out, r.monthDays(y, m, s.d)...)
				}
			}
		}
	}
	out = uniqDates(out)
	if len(r.bySetPos) > 0 && len(out) > 0 {
		var picked []localDate
		for _, p := range r.bySetPos {
			if d, ok := pickDate(out, p); ok {
				picked = append(picked, d)
			}
		}
		out = uniqDates(picked)
	}
	return out
}

func uniqDates(in []localDate) []localDate {
	seen := map[int]localDate{}
	for _, d := range in {
		seen[d.dayNumber()] = d
	}
	out := make([]localDate, 0, len(seen))
	for _, d := range seen {
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].less(out[j]) })
	return out
}

func (r *rrule) periodsBetween(a, b localDate) int {
	switch r.freq {
	case "DAILY":
		return (b.dayNumber() - a.dayNumber()) / r.interval
	case "WEEKLY":
		return (b.dayNumber() - a.dayNumber()) / (7 * r.interval)
	case "MONTHLY":
		return ((b.y-a.y)*12 + (b.m - a.m)) / r.interval
	}
	return (b.y - a.y) / r.interval
}

const maxRecurrenceIterations = 50000

func (r *rrule) iterate(start localDT, fromPeriod int, loc *time.Location, body func(localDT) bool) {
	emitted := 0
	pastUntil := func(c localDT) bool {
		switch r.untilKind {
		case "date":
			return r.untilDate.less(c.date)
		case "local":
			return r.untilLocal.less(c)
		case "utc":
			return c.in(loc).After(r.untilUTC)
		}
		return false
	}
	if fromPeriod == 0 {
		found := false
		for _, d := range r.candidates(0, start) {
			if d == start.date {
				found = true
			}
		}
		if !found {
			emitted++
			if !body(start) {
				return
			}
		}
	}
	period := fromPeriod
	for it := 0; it < maxRecurrenceIterations; it++ {
		for _, d := range r.candidates(period, start) {
			c := localDT{d, start.hour, start.min}
			if c.less(start) {
				continue
			}
			if pastUntil(c) {
				return
			}
			if r.count > 0 && emitted >= r.count {
				return
			}
			emitted++
			if !body(c) {
				return
			}
		}
		period++
	}
}

// expandOccurrences returns wall-clock starts overlapping [rangeStart, rangeEnd).
func expandOccurrences(start localDT, durationMin int, allDay bool, loc *time.Location, ruleText string,
	exdates map[string]bool, rangeStart, rangeEnd time.Time) []localDT {
	if allDay {
		start = localDT{start.date, 0, 0}
	}
	overlaps := func(s localDT) bool {
		sd := s.in(loc)
		var ed time.Time
		if allDay {
			dur := durationMin
			if dur < 1440 {
				dur = 1440
			}
			e := toLocalDT(sd, loc)
			ed = time.Date(e.date.y, time.Month(e.date.m), e.date.d+dur/1440, 0, 0, 0, 0, loc)
		} else {
			ed = sd.Add(time.Duration(durationMin) * time.Minute)
		}
		if ed.Equal(sd) {
			return !sd.Before(rangeStart) && sd.Before(rangeEnd)
		}
		return sd.Before(rangeEnd) && ed.After(rangeStart)
	}
	r := (*rrule)(nil)
	if ruleText != "" {
		r = parseRRule(ruleText)
	}
	if r == nil {
		if overlaps(start) && !exdates[start.key(allDay)] {
			return []localDT{start}
		}
		return nil
	}
	endLocal := toLocalDT(rangeEnd, loc)
	endLocal = localDT{endLocal.date.add(1), endLocal.hour, endLocal.min}
	startPeriod := 0
	if r.count == 0 {
		lead := durationMin
		if lead < 1440 {
			lead = 1440
		}
		earliest := toLocalDT(rangeStart.Add(-time.Duration(lead+1440)*time.Minute), loc).date
		if start.date.less(earliest) {
			if p := r.periodsBetween(start.date, earliest) - 1; p > 0 {
				startPeriod = p
			}
		}
	}
	var out []localDT
	r.iterate(start, startPeriod, loc, func(c localDT) bool {
		if endLocal.less(c) {
			return false
		}
		if !exdates[c.key(allDay)] && overlaps(c) {
			out = append(out, c)
		}
		return true
	})
	return out
}
