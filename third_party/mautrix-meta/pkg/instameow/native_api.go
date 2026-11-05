package instameow

import (
	"errors"
	"net/http"

	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
)

// InstagramNativeAPIHeaders uses the same authenticated device/profile as login.
// Callers must send these headers only to Instagram's native API, never a CDN.
func (c *Client) InstagramNativeAPIHeaders() (http.Header, error) {
	session := c.GetInstagramNativeSession()
	if session == nil || session.Authorization == "" || session.UserID == "" {
		return nil, errors.New("Instagram native session is unavailable")
	}
	d := session.Device
	state := &mobileLoginState{DeviceID: d.DeviceID, PhoneID: d.PhoneID, AndroidDeviceID: d.AndroidDeviceID, MachineID: d.MachineID}
	if d.USDID != "" && d.USDIDPrivateKey != "" {
		key, err := initializeUSDID(&d)
		if err != nil {
			return nil, err
		}
		state.USDIDHeader, err = makeUSDIDHeader(d, key)
		if err != nil {
			return nil, err
		}
	}
	h := c.mobileLoginHeaders(state)
	h.Set("authorization", session.Authorization)
	h.Set("ig-intended-user-id", session.UserID)
	h.Set("ig-u-ds-user-id", session.UserID)
	for key, value := range map[string]string{
		"ig-u-rur": session.RUR, "ig-u-shbid": session.SHBID, "ig-u-shbts": session.SHBTS,
		"ig-u-ig-direct-region-hint": session.DirectRegionHint, "x-ig-www-claim": session.WWWClaim,
	} {
		if value != "" {
			h.Set(key, value)
		}
	}
	return h, nil
}

// UpdateInstagramNativeAPIResponse applies session rotation using the existing
// login implementation, without creating another device or login session.
func (c *Client) UpdateInstagramNativeAPIResponse(response *http.Response) {
	session := c.GetInstagramNativeSession()
	if session == nil || response == nil {
		return
	}
	d := session.Device
	state := &mobileLoginState{DeviceID: d.DeviceID, PhoneID: d.PhoneID, AdvertisingID: d.AdvertisingID,
		AndroidDeviceID: d.AndroidDeviceID, MachineID: d.MachineID, USDID: d.USDID,
		USDIDKeyID: d.USDIDKeyID, USDIDPrivateKey: d.USDIDPrivateKey}
	c.cookies.UpdateFromResponse(response)
	if mid := response.Header.Get("ig-set-x-mid"); mid != "" {
		state.MachineID = mid
		c.cookies.Set(cookies.IGCookieMachineID, mid)
	}
	c.updateMobileSessionHeaders(response, state)
}
