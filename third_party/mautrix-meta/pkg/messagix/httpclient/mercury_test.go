package httpclient

import (
	"encoding/json"
	"testing"

	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

func TestEmptyUploadMetadataReturnsError(t *testing.T) {
	response := &types.MercuryUploadResponse{}
	response.Payload.Metadata = json.RawMessage(`[]`)
	if err := (&HTTPClient{}).parseMetadata(response); err == nil {
		t.Fatal("empty upload metadata must fail without indexing an empty slice")
	}
}
