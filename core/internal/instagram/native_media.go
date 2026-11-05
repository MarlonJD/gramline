package instagram

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"go.mau.fi/mautrix-meta/pkg/instameow"
)

// nativeMediaAPI supplements Slide GraphQL using the existing native session.
// Mutations are sent once; a transport error is never treated as permission to
// retry a view-once receipt. Response bodies and credentials are not logged.
type nativeMediaAPI struct{ client *instameow.Client }

func (a nativeMediaAPI) request(ctx context.Context, method, path string, form url.Values) ([]byte, int, error) {
	headers, err := a.client.InstagramNativeAPIHeaders()
	if err != nil {
		return nil, 0, err
	}
	address := "https://i.instagram.com/api/v1/" + path
	var body io.Reader
	if method == http.MethodGet {
		if len(form) > 0 {
			address += "?" + form.Encode()
		}
	} else {
		body = strings.NewReader(form.Encode())
		headers.Set("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
	}
	req, err := http.NewRequestWithContext(ctx, method, address, body)
	if err != nil {
		return nil, 0, err
	}
	req.Header = headers
	client := *a.client.GetHTTP().GetHTTPClient()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	response, err := client.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("native API transport failed")
	}
	defer response.Body.Close()
	a.client.UpdateInstagramNativeAPIResponse(response)
	const maximum = 16 << 20
	data, err := io.ReadAll(io.LimitReader(response.Body, maximum+1))
	if err != nil || len(data) > maximum {
		return nil, response.StatusCode, fmt.Errorf("native API response could not be read")
	}
	if response.StatusCode != http.StatusOK {
		return nil, response.StatusCode, fmt.Errorf("native API rejected request (HTTP %d)", response.StatusCode)
	}
	return data, response.StatusCode, nil
}
