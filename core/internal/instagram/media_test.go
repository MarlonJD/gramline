package instagram

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"insta-dm/core/internal/wire"
)

func mediaFixture(t *testing.T, bytes []byte, mime string) (*Backend, *fakeAPI, mediaInput) {
	t.Helper()
	b, api, _ := fixture()
	b.connected.Store(true)
	api.thread.ThreadKey = 100
	path := filepath.Join(t.TempDir(), "attachment")
	if err := os.WriteFile(path, bytes, 0600); err != nil {
		t.Fatal(err)
	}
	return b, api, mediaInput{ThreadID: "thread", ClientID: "123", Path: path, Attachment: Attachment{ID: "attachment", Filename: "example.file", MimeType: mime, ByteCount: len(bytes)}}
}

func TestMediaUploadPrecedesSingleCommitAndKeepsClientID(t *testing.T) {
	bytes, _ := base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")
	b, api, input := mediaFixture(t, bytes, "image/png")
	data, _ := json.Marshal(input)
	result, err := b.sendMedia(context.Background(), data)
	if err != nil {
		t.Fatal(err)
	}
	message := result.(Message)
	if api.uploadCalls != 1 || api.mediaCalls != 1 || api.mediaRequest.OfflineThreadingID != "123" || api.mediaRequest.ThreadID != "thread" || api.mediaRequest.AttachmentFBID != "42" {
		t.Fatal("upload/send routing or idempotency identifier changed")
	}
	if message.Status != "sent" || message.Kind != "image" || message.Attachment.ByteCount != len(bytes) {
		t.Fatalf("bad result: %+v", message)
	}
}

func TestFileUploadSanitizesMultipartFilename(t *testing.T) {
	b, api, input := mediaFixture(t, []byte("%PDF-1.4 test file"), "application/pdf")
	input.Attachment.Filename = "report\"\r\n.pdf"
	data, _ := json.Marshal(input)
	_, err := b.sendMedia(context.Background(), data)
	if err != nil {
		t.Fatal(err)
	}
	if api.uploaded.Filename != "report___.pdf" || api.uploaded.MimeType != "application/pdf" {
		t.Fatal("unsafe multipart metadata")
	}
}

func TestUploadFailureNeverCommitsAndCommitFailureIsUncertain(t *testing.T) {
	for _, failUpload := range []bool{true, false} {
		b, api, input := mediaFixture(t, []byte("test"), "text/plain")
		if failUpload {
			api.uploadError = errors.New("private upstream error")
		} else {
			api.mediaError = errors.New("lost response")
		}
		data, _ := json.Marshal(input)
		_, err := b.sendMedia(context.Background(), data)
		var fault *wire.Fault
		if !errors.As(err, &fault) {
			t.Fatal("expected safe fault")
		}
		if failUpload && (fault.Code != "not_sent" || api.mediaCalls != 0) {
			t.Fatal("failed upload reached commit")
		}
		if !failUpload && (fault.Code != "send_unknown" || api.mediaCalls != 1) {
			t.Fatal("uncertain commit was retried or misclassified")
		}
	}
}

func TestMediaRejectsOversizeAndMissingFilesBeforeUpload(t *testing.T) {
	for _, size := range []int64{0, maxFileBytes + 1} {
		b, api, input := mediaFixture(t, []byte("test"), "application/octet-stream")
		if err := os.Truncate(input.Path, size); err != nil {
			t.Fatal(err)
		}
		data, _ := json.Marshal(input)
		if _, err := b.sendMedia(context.Background(), data); err == nil {
			t.Fatal("invalid file accepted")
		}
		if api.uploadCalls != 0 || api.mediaCalls != 0 {
			t.Fatal("invalid file crossed network")
		}
	}
}
