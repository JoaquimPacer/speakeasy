package api

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestInviteCreationRateAndOutstandingCap(t *testing.T) {
	_, rateRelay, _ := newHardeningTestRelay(t, Options{
		RetentionDays:                   7,
		InviteRatePerAccount:            1,
		MaxOutstandingInvitesPerAccount: 5,
	})
	rateUser := registerTestDevice(t, rateRelay.URL, "invite-rate-user")
	postJSON(t, rateRelay.URL+"/contacts/invite", rateUser.BearerToken, map[string]any{}, http.StatusCreated, &inviteResponse{})
	postJSON(t, rateRelay.URL+"/contacts/invite", rateUser.BearerToken, map[string]any{}, http.StatusTooManyRequests, nil)

	database, capRelay, _ := newHardeningTestRelay(t, Options{
		RetentionDays:                   7,
		InviteRatePerAccount:            10,
		MaxOutstandingInvitesPerAccount: 1,
		MaxInviteRecordsPerAccount:      10,
		MaxInviteRecordsTotal:           10,
	})
	capUser := registerTestDevice(t, capRelay.URL, "invite-cap-user")
	var first inviteResponse
	postJSON(t, capRelay.URL+"/contacts/invite", capUser.BearerToken, map[string]any{}, http.StatusCreated, &first)
	postJSON(t, capRelay.URL+"/contacts/invite", capUser.BearerToken, map[string]any{}, http.StatusTooManyRequests, nil)
	if _, err := database.ExecContext(
		context.Background(),
		`UPDATE invites SET expires_at = ? WHERE id = ?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339),
		first.InviteID,
	); err != nil {
		t.Fatalf("expire outstanding invite: %v", err)
	}
	postJSON(t, capRelay.URL+"/contacts/invite", capUser.BearerToken, map[string]any{}, http.StatusCreated, &inviteResponse{})
}

func TestInviteDatabaseAccountAndGlobalCapsRejectWithoutDeleting(t *testing.T) {
	database, accountRelay, _ := newHardeningTestRelay(t, Options{
		RetentionDays:                   7,
		InviteRatePerAccount:            10,
		MaxOutstandingInvitesPerAccount: 5,
		MaxInviteRecordsPerAccount:      1,
		MaxInviteRecordsTotal:           10,
	})
	accountUser := registerTestDevice(t, accountRelay.URL, "invite-account-db-cap")
	var first inviteResponse
	postJSON(t, accountRelay.URL+"/contacts/invite", accountUser.BearerToken, map[string]any{}, http.StatusCreated, &first)
	if _, err := database.ExecContext(
		context.Background(),
		`UPDATE invites SET expires_at = ? WHERE id = ?`,
		time.Now().UTC().Add(-time.Hour).Format(time.RFC3339),
		first.InviteID,
	); err != nil {
		t.Fatalf("expire account-cap invite: %v", err)
	}
	postJSON(t, accountRelay.URL+"/contacts/invite", accountUser.BearerToken, map[string]any{}, http.StatusInsufficientStorage, nil)
	var accountCount int
	if err := database.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM invites`).Scan(&accountCount); err != nil {
		t.Fatalf("count retained account invites: %v", err)
	}
	if accountCount != 1 {
		t.Fatalf("retained account invite count = %d, want 1", accountCount)
	}

	globalDatabase, globalRelay, _ := newHardeningTestRelay(t, Options{
		RetentionDays:                   7,
		InviteRatePerAccount:            10,
		MaxOutstandingInvitesPerAccount: 5,
		MaxInviteRecordsPerAccount:      10,
		MaxInviteRecordsTotal:           1,
	})
	alice := registerTestDevice(t, globalRelay.URL, "invite-global-alice")
	bob := registerTestDevice(t, globalRelay.URL, "invite-global-bob")
	postJSON(t, globalRelay.URL+"/contacts/invite", alice.BearerToken, map[string]any{}, http.StatusCreated, &inviteResponse{})
	postJSON(t, globalRelay.URL+"/contacts/invite", bob.BearerToken, map[string]any{}, http.StatusInsufficientStorage, nil)
	var globalCount int
	if err := globalDatabase.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM invites`).Scan(&globalCount); err != nil {
		t.Fatalf("count retained global invites: %v", err)
	}
	if globalCount != 1 {
		t.Fatalf("retained global invite count = %d, want 1", globalCount)
	}
}

func TestReportRateIsAppliedOnlyToReportCreation(t *testing.T) {
	_, relay, _ := newHardeningTestRelay(t, Options{
		RetentionDays:        7,
		InviteRatePerAccount: 10,
		ReportRatePerAccount: 1,
	})
	alice := registerTestDevice(t, relay.URL, "report-rate-alice")
	bob := registerTestDevice(t, relay.URL, "report-rate-bob")
	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)

	postJSON(t, relay.URL+"/reports", bob.BearerToken, reportRequest{
		ReportedUserID: alice.User.ID,
		Reason:         "contact",
	}, http.StatusNoContent, nil)
	postJSON(t, relay.URL+"/reports", bob.BearerToken, reportRequest{
		ReportedUserID: alice.User.ID,
		Reason:         "contact",
	}, http.StatusTooManyRequests, nil)
}

func TestReportDatabaseCapsRejectAndNeverDeleteReports(t *testing.T) {
	database, accountRelay, _ := newHardeningTestRelay(t, Options{
		RetentionDays:              7,
		ReportRatePerAccount:       10,
		MaxReportRecordsPerAccount: 1,
		MaxReportRecordsTotal:      10,
	})
	alice := registerTestDevice(t, accountRelay.URL, "report-account-alice")
	bob := registerTestDevice(t, accountRelay.URL, "report-account-bob")
	report := reportRequest{ReportedUserID: bob.User.ID, Reason: "contact"}
	postJSON(t, accountRelay.URL+"/reports", alice.BearerToken, report, http.StatusNoContent, nil)
	postJSON(t, accountRelay.URL+"/reports", alice.BearerToken, report, http.StatusInsufficientStorage, nil)
	var accountCount int
	if err := database.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM reports`).Scan(&accountCount); err != nil {
		t.Fatalf("count retained account reports: %v", err)
	}
	if accountCount != 1 {
		t.Fatalf("retained account report count = %d, want 1", accountCount)
	}

	globalDatabase, globalRelay, _ := newHardeningTestRelay(t, Options{
		RetentionDays:              7,
		ReportRatePerAccount:       10,
		MaxReportRecordsPerAccount: 10,
		MaxReportRecordsTotal:      1,
	})
	globalAlice := registerTestDevice(t, globalRelay.URL, "report-global-alice")
	globalBob := registerTestDevice(t, globalRelay.URL, "report-global-bob")
	postJSON(t, globalRelay.URL+"/reports", globalAlice.BearerToken, reportRequest{
		ReportedUserID: globalBob.User.ID,
		Reason:         "contact",
	}, http.StatusNoContent, nil)
	postJSON(t, globalRelay.URL+"/reports", globalBob.BearerToken, reportRequest{
		ReportedUserID: globalAlice.User.ID,
		Reason:         "contact",
	}, http.StatusInsufficientStorage, nil)
	var globalCount int
	if err := globalDatabase.QueryRowContext(context.Background(), `SELECT COUNT(*) FROM reports`).Scan(&globalCount); err != nil {
		t.Fatalf("count retained global reports: %v", err)
	}
	if globalCount != 1 {
		t.Fatalf("retained global report count = %d, want 1", globalCount)
	}
}
