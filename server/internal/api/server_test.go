package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/joaquimpacer/speakeasy/server/internal/db"
	"github.com/joaquimpacer/speakeasy/server/internal/storage"
)

func TestLocalRelayVerticalSlice(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "alice")
	bob := registerTestDevice(t, relay.URL, "bob")

	invite := createInvite(t, relay.URL, alice.BearerToken)
	accepted := acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)
	if accepted.ContactID != alice.User.ID {
		t.Fatalf("accepted contactID = %q, want alice %q", accepted.ContactID, alice.User.ID)
	}
	if accepted.DeviceID != alice.Device.ID {
		t.Fatalf("accepted deviceID = %q, want alice device %q", accepted.DeviceID, alice.Device.ID)
	}

	bobContact := assertHasContact(t, relay.URL, alice.BearerToken, bob.User.ID)
	aliceContact := assertHasContact(t, relay.URL, bob.BearerToken, alice.User.ID)
	if bobContact.DeviceID != bob.Device.ID {
		t.Fatalf("alice contact deviceID = %q, want bob device %q", bobContact.DeviceID, bob.Device.ID)
	}
	if aliceContact.DeviceID != alice.Device.ID {
		t.Fatalf("bob contact deviceID = %q, want alice device %q", aliceContact.DeviceID, alice.Device.ID)
	}

	envelope := json.RawMessage(`{"version":1,"algorithm":"xchacha20poly1305","encryptedContentKey":"ZmFrZQ==","nonce":"bm9uY2U="}`)
	message := uploadTestMessage(t, relay.URL, alice.BearerToken, strings.ToUpper(bob.User.ID), strings.ToUpper(bob.Device.ID), envelope, []byte("ciphertext-video"))
	if message.Status != "sent" {
		t.Fatalf("uploaded message status = %q, want sent", message.Status)
	}
	if message.SenderDeviceID != alice.Device.ID {
		t.Fatalf("uploaded senderDeviceID = %q, want alice device %q", message.SenderDeviceID, alice.Device.ID)
	}
	if message.RecipientDeviceID != bob.Device.ID {
		t.Fatalf("uploaded recipientDeviceID = %q, want bob device %q", message.RecipientDeviceID, bob.Device.ID)
	}
	if !bytes.Equal(message.Envelope, envelope) {
		t.Fatalf("uploaded envelope = %s, want %s", message.Envelope, envelope)
	}

	messages := listMessages(t, relay.URL, bob.BearerToken)
	if len(messages) != 1 {
		t.Fatalf("bob message count = %d, want 1", len(messages))
	}
	if messages[0].ID != message.ID {
		t.Fatalf("bob message id = %q, want %q", messages[0].ID, message.ID)
	}
	if messages[0].RecipientDeviceID != bob.Device.ID {
		t.Fatalf("bob message recipientDeviceID = %q, want %q", messages[0].RecipientDeviceID, bob.Device.ID)
	}

	downloaded := downloadMessage(t, relay.URL, bob.BearerToken, strings.ToUpper(message.ID))
	if string(downloaded) != "ciphertext-video" {
		t.Fatalf("downloaded blob = %q, want ciphertext-video", string(downloaded))
	}

	delivered := acknowledgeDelivered(t, relay.URL, bob.BearerToken, strings.ToUpper(message.ID))
	if delivered.Status != "delivered" || !delivered.BlobDeleted {
		t.Fatalf("delivered response = %+v, want delivered with blobDeleted", delivered)
	}

	statusCode := downloadMessageStatus(t, relay.URL, bob.BearerToken, message.ID)
	if statusCode != http.StatusGone {
		t.Fatalf("download after delivery status = %d, want %d", statusCode, http.StatusGone)
	}

	messages = listMessages(t, relay.URL, bob.BearerToken)
	if len(messages) != 1 {
		t.Fatalf("bob message count after delivery = %d, want 1", len(messages))
	}
	if messages[0].Status != "delivered" {
		t.Fatalf("message status after delivery = %q, want delivered", messages[0].Status)
	}
	if messages[0].EncryptedBlobPath != "" {
		t.Fatalf("encryptedBlobPath after delivery = %q, want empty", messages[0].EncryptedBlobPath)
	}
}

func TestDeleteAccountRemovesServerRecordsAndBlobs(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "delete-alice")
	bob := registerTestDevice(t, relay.URL, "delete-bob")

	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)
	envelope := json.RawMessage(`{"version":1,"algorithm":"xchacha20poly1305","encryptedContentKey":"ZmFrZQ==","nonce":"bm9uY2U="}`)
	message := uploadTestMessage(t, relay.URL, alice.BearerToken, bob.User.ID, bob.Device.ID, envelope, []byte("pending-ciphertext-video"))

	if statusCode := downloadMessageStatus(t, relay.URL, bob.BearerToken, message.ID); statusCode != http.StatusOK {
		t.Fatalf("download before account deletion status = %d, want %d", statusCode, http.StatusOK)
	}

	deleteAccount(t, relay.URL, bob.BearerToken)

	if statusCode := getStatus(t, relay.URL+"/contacts", bob.BearerToken); statusCode != http.StatusUnauthorized {
		t.Fatalf("deleted account auth status = %d, want %d", statusCode, http.StatusUnauthorized)
	}
	if statusCode := downloadMessageStatus(t, relay.URL, alice.BearerToken, message.ID); statusCode != http.StatusNotFound {
		t.Fatalf("download after account deletion status = %d, want %d", statusCode, http.StatusNotFound)
	}

	aliceContacts := listContacts(t, relay.URL, alice.BearerToken)
	for _, contact := range aliceContacts {
		if contact.ContactID == bob.User.ID {
			t.Fatalf("deleted account remained in contacts: %+v", contact)
		}
	}
}

func TestDeleteContactRemovesOnlyRequesterContact(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "delete-contact-alice")
	bob := registerTestDevice(t, relay.URL, "delete-contact-bob")
	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)

	assertHasContact(t, relay.URL, alice.BearerToken, bob.User.ID)
	assertHasContact(t, relay.URL, bob.BearerToken, alice.User.ID)

	deleteContact(t, relay.URL, alice.BearerToken, bob.User.ID)

	aliceContacts := listContacts(t, relay.URL, alice.BearerToken)
	for _, contact := range aliceContacts {
		if contact.ContactID == bob.User.ID {
			t.Fatalf("deleted contact remained in alice contacts: %+v", contact)
		}
	}
	assertHasContact(t, relay.URL, bob.BearerToken, alice.User.ID)
}

func TestBlockContactRemovesContactAndRejectsBlockedSender(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "block-alice")
	bob := registerTestDevice(t, relay.URL, "block-bob")
	invite := createInvite(t, relay.URL, alice.BearerToken)
	_ = acceptInvite(t, relay.URL, bob.BearerToken, invite.Code)

	blockContact(t, relay.URL, alice.BearerToken, bob.User.ID)

	aliceContacts := listContacts(t, relay.URL, alice.BearerToken)
	for _, contact := range aliceContacts {
		if contact.ContactID == bob.User.ID {
			t.Fatalf("blocked contact remained in alice contacts: %+v", contact)
		}
	}
	assertHasContact(t, relay.URL, bob.BearerToken, alice.User.ID)

	envelope := json.RawMessage(`{"version":1,"algorithm":"xchacha20poly1305","encryptedContentKey":"ZmFrZQ==","nonce":"bm9uY2U="}`)
	statusCode := uploadTestMessageStatus(t, relay.URL, bob.BearerToken, alice.User.ID, alice.Device.ID, envelope, []byte("blocked-ciphertext-video"))
	if statusCode != http.StatusForbidden {
		t.Fatalf("blocked sender upload status = %d, want %d", statusCode, http.StatusForbidden)
	}
}

func TestReportContactStoresMetadataOnlyReport(t *testing.T) {
	ctx := context.Background()
	database, err := db.Open(ctx, ":memory:")
	if err != nil {
		t.Fatalf("db.Open() error = %v", err)
	}
	t.Cleanup(func() { database.Close() })

	blobStore, err := storage.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("storage.NewLocal() error = %v", err)
	}

	relay := httptest.NewServer(New(database, blobStore, 7).Handler())
	t.Cleanup(relay.Close)

	alice := registerTestDevice(t, relay.URL, "report-alice")
	bob := registerTestDevice(t, relay.URL, "report-bob")

	reportContact(t, relay.URL, alice.BearerToken, bob.User.ID)

	var reportCount int
	if err := database.QueryRowContext(
		ctx,
		`SELECT COUNT(*) FROM reports
		  WHERE reporter_user_id = ? AND reported_user_id = ? AND reason = 'contact'`,
		alice.User.ID,
		bob.User.ID,
	).Scan(&reportCount); err != nil {
		t.Fatalf("count reports: %v", err)
	}
	if reportCount != 1 {
		t.Fatalf("report count = %d, want 1", reportCount)
	}
}

func registerTestDevice(t *testing.T, baseURL string, username string) authSessionResponse {
	t.Helper()

	var session authSessionResponse
	postJSON(t, baseURL+"/auth/register", "", registerRequest{
		Username:            username,
		DeviceName:          username + " iPhone",
		EncryptionPublicKey: []byte(strings.Repeat("e", 32)),
		SigningPublicKey:    []byte(strings.Repeat("s", 32)),
	}, http.StatusCreated, &session)
	return session
}

func createInvite(t *testing.T, baseURL string, token string) inviteResponse {
	t.Helper()

	var invite inviteResponse
	postJSON(t, baseURL+"/contacts/invite", token, map[string]any{}, http.StatusCreated, &invite)
	if invite.Code == "" {
		t.Fatalf("invite code is empty")
	}
	return invite
}

func acceptInvite(t *testing.T, baseURL string, token string, code string) contactResponse {
	t.Helper()

	var contact contactResponse
	postJSON(t, baseURL+"/contacts/accept", token, acceptInviteRequest{Code: code}, http.StatusOK, &contact)
	return contact
}

func assertHasContact(t *testing.T, baseURL string, token string, contactID string) contactResponse {
	t.Helper()

	var contacts []contactResponse
	getJSON(t, baseURL+"/contacts", token, http.StatusOK, &contacts)
	for _, contact := range contacts {
		if contact.ContactID == contactID {
			if contact.DeviceID == "" {
				t.Fatalf("contact %q has empty deviceID", contactID)
			}
			return contact
		}
	}
	t.Fatalf("contact %q not found in %+v", contactID, contacts)
	return contactResponse{}
}

func listContacts(t *testing.T, baseURL string, token string) []contactResponse {
	t.Helper()

	var contacts []contactResponse
	getJSON(t, baseURL+"/contacts", token, http.StatusOK, &contacts)
	return contacts
}

func uploadTestMessage(t *testing.T, baseURL string, token string, recipientID string, recipientDeviceID string, envelope json.RawMessage, blob []byte) messageResponse {
	t.Helper()

	request := newUploadRequest(t, baseURL, token, recipientID, recipientDeviceID, envelope, blob)
	var message messageResponse
	doRequest(t, request, http.StatusCreated, &message)
	return message
}

func uploadTestMessageStatus(t *testing.T, baseURL string, token string, recipientID string, recipientDeviceID string, envelope json.RawMessage, blob []byte) int {
	t.Helper()

	request := newUploadRequest(t, baseURL, token, recipientID, recipientDeviceID, envelope, blob)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("upload message status: %v", err)
	}
	defer response.Body.Close()
	return response.StatusCode
}

func newUploadRequest(t *testing.T, baseURL string, token string, recipientID string, recipientDeviceID string, envelope json.RawMessage, blob []byte) *http.Request {
	t.Helper()

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)

	metadata, err := json.Marshal(uploadMetadata{
		RecipientID:       recipientID,
		RecipientDeviceID: recipientDeviceID,
		Envelope:          envelope,
		BlobSize:          int64(len(blob)),
		DurationMs:        42000,
	})
	if err != nil {
		t.Fatalf("marshal metadata: %v", err)
	}

	metadataPart, err := writer.CreateFormField("metadata")
	if err != nil {
		t.Fatalf("create metadata part: %v", err)
	}
	if _, err := metadataPart.Write(metadata); err != nil {
		t.Fatalf("write metadata part: %v", err)
	}

	blobPart, err := writer.CreateFormFile("blob", "message.blob")
	if err != nil {
		t.Fatalf("create blob part: %v", err)
	}
	if _, err := blobPart.Write(blob); err != nil {
		t.Fatalf("write blob part: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}

	request, err := http.NewRequest(http.MethodPost, baseURL+"/messages", &body)
	if err != nil {
		t.Fatalf("new upload request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	return request
}

func listMessages(t *testing.T, baseURL string, token string) []messageResponse {
	t.Helper()

	var messages []messageResponse
	getJSON(t, baseURL+"/messages", token, http.StatusOK, &messages)
	return messages
}

func downloadMessage(t *testing.T, baseURL string, token string, messageID string) []byte {
	t.Helper()

	request := authedRequest(t, http.MethodGet, baseURL+"/messages/"+messageID, token, nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("download message: %v", err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read download body: %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("download status = %d, body = %s", response.StatusCode, string(body))
	}
	return body
}

func downloadMessageStatus(t *testing.T, baseURL string, token string, messageID string) int {
	t.Helper()

	request := authedRequest(t, http.MethodGet, baseURL+"/messages/"+messageID, token, nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("download message status: %v", err)
	}
	defer response.Body.Close()
	return response.StatusCode
}

func acknowledgeDelivered(t *testing.T, baseURL string, token string, messageID string) deliveredResponse {
	t.Helper()

	var delivered deliveredResponse
	postJSON(t, baseURL+"/messages/"+messageID+"/delivered", token, map[string]any{}, http.StatusOK, &delivered)
	return delivered
}

func deleteAccount(t *testing.T, baseURL string, token string) {
	t.Helper()

	request := authedRequest(t, http.MethodDelete, baseURL+"/account", token, nil)
	doRequest(t, request, http.StatusNoContent, nil)
}

func deleteContact(t *testing.T, baseURL string, token string, contactID string) {
	t.Helper()

	request := authedRequest(t, http.MethodDelete, baseURL+"/contacts/"+contactID, token, nil)
	doRequest(t, request, http.StatusNoContent, nil)
}

func blockContact(t *testing.T, baseURL string, token string, blockedUserID string) {
	t.Helper()

	postJSON(t, baseURL+"/blocks", token, blockRequest{BlockedUserID: blockedUserID}, http.StatusNoContent, nil)
}

func reportContact(t *testing.T, baseURL string, token string, reportedUserID string) {
	t.Helper()

	postJSON(t, baseURL+"/reports", token, reportRequest{
		ReportedUserID: reportedUserID,
		Reason:         "contact",
		Details:        "metadata-only report",
	}, http.StatusNoContent, nil)
}

func getStatus(t *testing.T, url string, token string) int {
	t.Helper()

	response, err := http.DefaultClient.Do(authedRequest(t, http.MethodGet, url, token, nil))
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer response.Body.Close()
	return response.StatusCode
}

func getJSON(t *testing.T, url string, token string, wantStatus int, target any) {
	t.Helper()
	doRequest(t, authedRequest(t, http.MethodGet, url, token, nil), wantStatus, target)
}

func postJSON(t *testing.T, url string, token string, payload any, wantStatus int, target any) {
	t.Helper()

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal JSON body: %v", err)
	}

	request := authedRequest(t, http.MethodPost, url, token, bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	doRequest(t, request, wantStatus, target)
}

func authedRequest(t *testing.T, method string, url string, token string, body io.Reader) *http.Request {
	t.Helper()

	request, err := http.NewRequest(method, url, body)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	return request
}

func doRequest(t *testing.T, request *http.Request, wantStatus int, target any) {
	t.Helper()

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("%s %s: %v", request.Method, request.URL, err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read response body: %v", err)
	}
	if response.StatusCode != wantStatus {
		t.Fatalf("%s %s status = %d, want %d, body = %s", request.Method, request.URL, response.StatusCode, wantStatus, string(body))
	}
	if target == nil {
		return
	}
	if err := json.Unmarshal(body, target); err != nil {
		t.Fatalf("decode response JSON: %v; body = %s", err, string(body))
	}
}
