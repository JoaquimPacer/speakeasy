package api

import (
	"bytes"
	"context"
	"net/http"
	"strings"
	"testing"
)

func TestReportFieldsEnforceStrictUTF8ByteLimits(t *testing.T) {
	database, relay, _ := newHardeningTestRelay(t, Options{RetentionDays: 7})
	alice := registerTestDevice(t, relay.URL, "report-limit-alice")
	bob := registerTestDevice(t, relay.URL, "report-limit-bob")

	postJSON(t, relay.URL+"/reports", alice.BearerToken, reportRequest{
		ReportedUserID: bob.User.ID,
		Reason:         strings.Repeat("r", maxReportReasonUTF8Bytes+1),
	}, http.StatusBadRequest, nil)
	postJSON(t, relay.URL+"/reports", alice.BearerToken, reportRequest{
		ReportedUserID: bob.User.ID,
		Reason:         "contact",
		Details:        strings.Repeat("d", maxReportDetailsUTF8Bytes+1),
	}, http.StatusBadRequest, nil)

	invalidJSON := append(
		[]byte(`{"reportedUserID":"`+bob.User.ID+`","reason":"`),
		0xff,
	)
	invalidJSON = append(invalidJSON, []byte(`"}`)...)
	request := authedRequest(t, http.MethodPost, relay.URL+"/reports", alice.BearerToken, bytes.NewReader(invalidJSON))
	request.Header.Set("Content-Type", "application/json")
	doRequest(t, request, http.StatusBadRequest, nil)

	postJSON(t, relay.URL+"/reports", alice.BearerToken, map[string]any{
		"reportedUserID": bob.User.ID,
		"reason":         "contact",
		"details":        "metadata-only report",
		"unexpected":     true,
	}, http.StatusBadRequest, nil)

	postJSON(t, relay.URL+"/reports", alice.BearerToken, reportRequest{
		ReportedUserID: bob.User.ID,
		Reason:         strings.Repeat("r", maxReportReasonUTF8Bytes),
		Details:        strings.Repeat("d", maxReportDetailsUTF8Bytes),
	}, http.StatusNoContent, nil)

	var reportCount int
	if err := database.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM reports`).Scan(&reportCount); err != nil {
		t.Fatalf("count reports: %v", err)
	}
	if reportCount != 1 {
		t.Fatalf("report count = %d, want 1 accepted boundary report", reportCount)
	}
}
