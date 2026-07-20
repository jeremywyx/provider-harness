package clients

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Client is a simple Harness API REST client.
type Client struct {
	APIKey     string
	AccountID  string
	Endpoint   string
	HTTPClient *http.Client
}

// NewClient creates a new Harness client.
func NewClient(apiKey, accountID, endpoint string) *Client {
	if endpoint == "" {
		endpoint = "https://app.harness.io"
	}
	return &Client{
		APIKey:     apiKey,
		AccountID:  accountID,
		Endpoint:   endpoint,
		HTTPClient: &http.Client{Timeout: 30 * time.Second},
	}
}

// TokenData is the struct matching Harness token data envelope.
type TokenData struct {
	ID          string `json:"-"`
	Name        string `json:"name"`
	TokenStatus string `json:"status"`
	Value       string `json:"value"`
	Created     int64  `json:"createdAt"`
}

// TokenResponse envelopes a single token response.
type TokenResponse struct {
	Resource TokenData `json:"resource"`
}

// TokenListResponse envelopes a list token response.
type TokenListResponse struct {
	Resource []TokenData `json:"resource"`
}

// DelegateData is the struct matching Harness delegate data envelope.
type DelegateData struct {
	ID           string `json:"uuid"`
	Name         string `json:"name"`
	Hostname     string `json:"hostName"`
	Status       string `json:"status"`
	Version      string `json:"version"`
	DelegateType string `json:"type"`
}

// DelegateListResponse envelopes a list delegate response.
type DelegateListResponse struct {
	Resource []DelegateData `json:"resource"`
}

func (c *Client) request(ctx context.Context, method, path string, query map[string]string, body any, target any) error {
	url := fmt.Sprintf("%s%s", c.Endpoint, path)
	req, err := http.NewRequestWithContext(ctx, method, url, nil)
	if err != nil {
		return err
	}

	q := req.URL.Query()
	q.Add("accountIdentifier", c.AccountID)
	for k, v := range query {
		q.Add(k, v)
	}
	req.URL.RawQuery = q.Encode()

	if body != nil {
		buf := new(bytes.Buffer)
		if err := json.NewEncoder(buf).Encode(body); err != nil {
			return err
		}
		req.Body = io.NopCloser(buf)
		req.Header.Set("Content-Type", "application/json")
	}

	req.Header.Set("x-api-key", c.APIKey)

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("API request failed with status %d: %s", resp.StatusCode, string(b))
	}

	if target != nil {
		return json.NewDecoder(resp.Body).Decode(target)
	}
	return nil
}

// CreateDelegateToken creates a new delegate token.
func (c *Client) CreateDelegateToken(ctx context.Context, orgID, projectID, name string) (*TokenData, error) {
	query := map[string]string{
		"tokenName":   name,
	}
	if orgID != "" {
		query["orgIdentifier"] = orgID
	}
	if projectID != "" {
		query["projectIdentifier"] = projectID
	}

	var resp TokenResponse
	err := c.request(ctx, "POST", "/ng/api/delegate-token-ng", query, nil, &resp)
	if err != nil {
		return nil, err
	}
	resp.Resource.ID = resp.Resource.Name
	return &resp.Resource, nil
}

// GetDelegateToken retrieves a delegate token by its name.
func (c *Client) GetDelegateToken(ctx context.Context, orgID, projectID, name string) (*TokenData, error) {
	query := map[string]string{}
	if orgID != "" {
		query["orgIdentifier"] = orgID
	}
	if projectID != "" {
		query["projectIdentifier"] = projectID
	}

	var resp TokenListResponse
	err := c.request(ctx, "GET", "/ng/api/delegate-token-ng", query, nil, &resp)
	if err != nil {
		return nil, err
	}

	for i := range resp.Resource {
		resp.Resource[i].ID = resp.Resource[i].Name
		if resp.Resource[i].Name == name {
			return &resp.Resource[i], nil
		}
	}
	return nil, nil // Not found
}

// RevokeDelegateToken revokes an active delegate token.
func (c *Client) RevokeDelegateToken(ctx context.Context, orgID, projectID, tokenIdentifier string) error {
	query := map[string]string{
		"tokenIdentifier": tokenIdentifier,
		"tokenName":       tokenIdentifier,
	}
	if orgID != "" {
		query["orgIdentifier"] = orgID
	}
	if projectID != "" {
		query["projectIdentifier"] = projectID
	}

	return c.request(ctx, "PUT", "/ng/api/delegate-token-ng", query, nil, nil)
}

// DeleteDelegateToken revokes and then deletes a delegate token.
func (c *Client) DeleteDelegateToken(ctx context.Context, orgID, projectID, tokenIdentifier string) error {
	query := map[string]string{
		"tokenIdentifier": tokenIdentifier,
		"tokenName":       tokenIdentifier,
	}
	if orgID != "" {
		query["orgIdentifier"] = orgID
	}
	if projectID != "" {
		query["projectIdentifier"] = projectID
	}

	// First attempt to revoke
	_ = c.RevokeDelegateToken(ctx, orgID, projectID, tokenIdentifier)

	return c.request(ctx, "DELETE", "/ng/api/delegate-token-ng", query, nil, nil)
}

// GetDelegate lists delegates and filters to find the one matching the given identifier (name or uuid).
func (c *Client) GetDelegate(ctx context.Context, orgID, projectID, identifier string) (*DelegateData, error) {
	query := map[string]string{
		"scope": "true",
	}
	if orgID != "" {
		query["orgIdentifier"] = orgID
	}
	if projectID != "" {
		query["projectIdentifier"] = projectID
	}

	var resp DelegateListResponse
	body := map[string]any{}
	err := c.request(ctx, "POST", "/ng/api/delegate-setup/listDelegates", query, body, &resp)
	if err != nil {
		return nil, err
	}

	for _, del := range resp.Resource {
		if del.Name == identifier || del.ID == identifier {
			return &del, nil
		}
	}
	return nil, nil // Not found
}

// DeleteDelegate deletes the delegate registration from the control plane.
func (c *Client) DeleteDelegate(ctx context.Context, orgID, projectID, identifier string) error {
	query := map[string]string{}
	if orgID != "" {
		query["orgIdentifier"] = orgID
	}
	if projectID != "" {
		query["projectIdentifier"] = projectID
	}

	path := fmt.Sprintf("/ng/api/delegate-setup/delegate/%s", identifier)
	return c.request(ctx, "DELETE", path, query, nil, nil)
}
