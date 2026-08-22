package api

import (
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

func TestScopedRateRejectionDoesNotConsumeGlobalAllowance(t *testing.T) {
	server := &Server{now: func() time.Time {
		return time.Date(2026, time.August, 9, 12, 0, 0, 0, time.UTC)
	}}
	scoped := newFixedWindowLimiter(1, time.Hour)
	global := newFixedWindowLimiter(2, time.Hour)

	if !server.allowScopedThenGlobal(httptest.NewRecorder(), scoped, "first", global) {
		t.Fatal("first scoped request was rejected")
	}
	for range 5 {
		recorder := httptest.NewRecorder()
		if server.allowScopedThenGlobal(recorder, scoped, "first", global) {
			t.Fatal("exhausted scoped key was allowed")
		}
		if recorder.Code != 429 || recorder.Header().Get("Retry-After") == "" {
			t.Fatalf("scoped rejection = status %d Retry-After %q", recorder.Code, recorder.Header().Get("Retry-After"))
		}
	}
	if !server.allowScopedThenGlobal(httptest.NewRecorder(), scoped, "second", global) {
		t.Fatal("blocked first key consumed the remaining global allowance")
	}
}

func TestGlobalRateRejectionDoesNotCreateOrConsumeScopedAllowance(t *testing.T) {
	now := time.Date(2026, time.August, 9, 12, 0, 0, 0, time.UTC)
	server := &Server{now: func() time.Time { return now }}
	scoped := newFixedWindowLimiter(2, time.Hour)
	global := newFixedWindowLimiter(1, time.Minute)

	if !server.allowScopedThenGlobal(httptest.NewRecorder(), scoped, "admitted", global) {
		t.Fatal("initial request was rejected")
	}
	for index := range 100 {
		key := "rejected-" + strconv.Itoa(index)
		recorder := httptest.NewRecorder()
		if server.allowScopedThenGlobal(recorder, scoped, key, global) {
			t.Fatalf("globally exhausted request %q was allowed", key)
		}
		if recorder.Code != 429 {
			t.Fatalf("globally exhausted request %q status = %d, want 429", key, recorder.Code)
		}
	}
	if got := len(scoped.entries); got != 1 {
		t.Fatalf("scoped entries after globally rejected unique keys = %d, want 1", got)
	}
	if _, ok := scoped.entries["rejected-0"]; ok {
		t.Fatal("globally rejected scope allocated an entry")
	}

	now = now.Add(time.Minute)
	if !server.allowScopedThenGlobal(httptest.NewRecorder(), scoped, "rejected-0", global) {
		t.Fatal("globally rejected scope did not retain its first scoped allowance")
	}
	if got := scoped.entries["rejected-0"].count; got != 1 {
		t.Fatalf("newly admitted scoped count = %d, want 1", got)
	}
}

func TestFixedWindowLimiterCapsLiveKeysWithoutEviction(t *testing.T) {
	now := time.Date(2026, time.August, 9, 12, 0, 0, 0, time.UTC)
	limiter := newFixedWindowLimiterWithMaxKeys(2, time.Hour, 2)

	if allowed, _ := limiter.allow("first", now); !allowed {
		t.Fatal("first key was rejected")
	}
	if allowed, _ := limiter.allow("second", now.Add(30*time.Minute)); !allowed {
		t.Fatal("second key was rejected")
	}
	if allowed, retryAfter := limiter.allow("third", now.Add(45*time.Minute)); allowed {
		t.Fatal("new key was allowed after the live-key cap was reached")
	} else if retryAfter != 15*time.Minute {
		t.Fatalf("capacity retry = %s, want 15m", retryAfter)
	}
	if _, ok := limiter.entries["first"]; !ok {
		t.Fatal("capacity rejection evicted the first live counter")
	}
	if _, ok := limiter.entries["second"]; !ok {
		t.Fatal("capacity rejection evicted the second live counter")
	}

	if allowed, _ := limiter.allow("second", now.Add(50*time.Minute)); !allowed {
		t.Fatal("existing key with allowance was rejected at capacity")
	}
	if got := limiter.entries["second"].count; got != 2 {
		t.Fatalf("existing key count at capacity = %d, want 2", got)
	}

	if allowed, _ := limiter.allow("third", now.Add(time.Hour)); !allowed {
		t.Fatal("new key was not admitted after an expired entry was swept")
	}
	if _, ok := limiter.entries["first"]; ok {
		t.Fatal("expired first entry was not swept under capacity pressure")
	}
	if _, ok := limiter.entries["second"]; !ok {
		t.Fatal("live second entry was evicted while sweeping capacity")
	}
}

func TestRetryAfterUsesCeilingSeconds(t *testing.T) {
	now := time.Date(2026, time.August, 9, 12, 0, 0, 0, time.UTC)
	server := &Server{now: func() time.Time { return now }}
	limiter := newFixedWindowLimiter(1, 1500*time.Millisecond)

	if !server.allowRate(httptest.NewRecorder(), limiter, "caller") {
		t.Fatal("initial request was rejected")
	}
	now = now.Add(100 * time.Millisecond)
	recorder := httptest.NewRecorder()
	if server.allowRate(recorder, limiter, "caller") {
		t.Fatal("exhausted request was allowed")
	}
	if got := recorder.Header().Get("Retry-After"); got != "2" {
		t.Fatalf("Retry-After = %q, want ceiling value 2", got)
	}
}

func TestClientIPPrefersOverwrittenRealIPThenRightmostForwarded(t *testing.T) {
	server := &Server{options: Options{TrustProxyHeaders: true}}
	request := httptest.NewRequest("GET", "http://relay.test/healthz", nil)
	request.RemoteAddr = "172.18.0.1:54321"
	request.Header.Set("X-Real-IP", "198.51.100.7")
	request.Header.Set("X-Forwarded-For", "192.0.2.123, 203.0.113.9")
	if got := server.clientIP(request); got != "198.51.100.7" {
		t.Fatalf("clientIP with X-Real-IP = %q, want 198.51.100.7", got)
	}

	request.Header.Del("X-Real-IP")
	if got := server.clientIP(request); got != "203.0.113.9" {
		t.Fatalf("clientIP with forwarded chain = %q, want rightmost 203.0.113.9", got)
	}

	server.options.TrustProxyHeaders = false
	if got := server.clientIP(request); got != "172.18.0.1" {
		t.Fatalf("clientIP with untrusted headers = %q, want direct peer 172.18.0.1", got)
	}
}

func TestClientIPRejectsMalformedTrustedProxyValues(t *testing.T) {
	server := &Server{options: Options{TrustProxyHeaders: true}}
	request := httptest.NewRequest("GET", "http://relay.test/healthz", nil)
	request.RemoteAddr = "172.18.0.1:54321"
	request.Header.Set("X-Real-IP", "not-an-ip")
	request.Header.Set("X-Forwarded-For", "192.0.2.123, also-not-an-ip, 203.0.113.9")

	if got := server.clientIP(request); got != "203.0.113.9" {
		t.Fatalf("clientIP with malformed proxy values = %q, want rightmost valid 203.0.113.9", got)
	}

	request.Header.Set("X-Forwarded-For", "not-an-ip, still-not-an-ip")
	if got := server.clientIP(request); got != "172.18.0.1" {
		t.Fatalf("clientIP with no valid proxy value = %q, want direct peer 172.18.0.1", got)
	}
}
