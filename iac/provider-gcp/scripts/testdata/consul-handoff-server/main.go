package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type state struct {
	OldValid           bool            `json:"old_valid"`
	CandidateValid     bool            `json:"candidate_valid"`
	PreexistingValid   bool            `json:"preexisting_valid,omitempty"`
	Lineage            json.RawMessage `json:"lineage,omitempty"`
	LineageModifyIndex uint64          `json:"lineage_modify_index,omitempty"`
}

var stateMu sync.Mutex

func tokenDocument(accessor, description string, candidate, expanded bool) map[string]any {
	document := map[string]any{
		"AccessorID":          accessor,
		"Description":         description,
		"Policies":            []any{map[string]any{"ID": "policy-global", "Name": "global-management"}},
		"Roles":               []any{},
		"ServiceIdentities":   []any{},
		"NodeIdentities":      []any{},
		"TemplatedPolicies":   []any{},
		"Local":               false,
		"AuthMethod":          "",
		"AuthMethodNamespace": "",
		"ExpirationTTL":       0,
		"ExpirationTime":      nil,
	}
	if candidate {
		switch os.Getenv("FAKE_CANDIDATE_DURABILITY") {
		case "":
		case "local":
			document["Local"] = true
		case "auth-method":
			document["AuthMethod"] = "oidc"
		case "expiring":
			document["ExpirationTTL"] = int64(time.Hour)
			document["ExpirationTime"] = "2030-01-01T00:00:00Z"
		default:
			panic("unknown FAKE_CANDIDATE_DURABILITY")
		}
	}
	if expanded {
		document["ExpandedPolicies"] = []any{map[string]any{
			"ID": "policy-global", "Name": "global-management", "Rules": "acl = \"write\"\noperator = \"write\"",
		}}
		document["ExpandedRoles"] = []any{}
	}
	return document
}

func extraAuthorityDocument(kind string, expanded bool) map[string]any {
	const accessor = "33333333-3333-4333-8333-333333333333"
	document := map[string]any{
		"AccessorID":          accessor,
		"Description":         "Injected effective ACL-write authority",
		"Policies":            []any{},
		"Roles":               []any{},
		"ServiceIdentities":   []any{},
		"NodeIdentities":      []any{},
		"TemplatedPolicies":   []any{},
		"Local":               false,
		"AuthMethod":          "",
		"AuthMethodNamespace": "",
		"ExpirationTTL":       0,
		"ExpirationTime":      nil,
	}
	policyRules := "acl = \"write\""
	if kind == "comment-policy" {
		policyRules = "acl /* retained authority */\n =\n \"write\""
	} else if kind == "json-policy" {
		policyRules = `{"acl":"write"}`
	}
	customPolicy := map[string]any{
		"ID": "policy-custom-acl-write", "Name": "custom-acl-write", "Rules": policyRules,
	}
	switch kind {
	case "custom-policy", "comment-policy", "json-policy":
		document["Policies"] = []any{map[string]any{"ID": "policy-custom-acl-write", "Name": "custom-acl-write"}}
	case "role":
		document["Roles"] = []any{map[string]any{"ID": "role-acl-write", "Name": "acl-write-role"}}
	case "templated-policy":
		document["TemplatedPolicies"] = []any{map[string]any{"TemplateName": "builtin/nomad-server", "TemplateID": "template-nomad-server"}}
	case "":
		panic("empty extra authority kind")
	default:
		panic("unknown FAKE_EXTRA_AUTHORITY_KIND")
	}
	if expanded {
		document["ExpandedPolicies"] = []any{customPolicy}
		if kind == "role" {
			document["ExpandedRoles"] = []any{map[string]any{
				"ID": "role-acl-write", "Name": "acl-write-role",
				"Policies":          []any{map[string]any{"ID": "policy-custom-acl-write", "Name": "custom-acl-write"}},
				"TemplatedPolicies": []any{},
			}}
		} else {
			document["ExpandedRoles"] = []any{}
		}
	}
	return document
}

func writeJSON(w http.ResponseWriter, value any) {
	if err := json.NewEncoder(w).Encode(value); err != nil {
		panic(err)
	}
}

func readState(path string) (state, error) {
	var current state
	data, err := os.ReadFile(path)
	if err != nil {
		return current, err
	}
	err = json.Unmarshal(data, &current)
	return current, err
}

func writeState(path string, current state) error {
	data, err := json.Marshal(current)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

func injectedHTTP(w http.ResponseWriter, mode string) bool {
	switch mode {
	case "":
		return false
	case "500":
		http.Error(w, "injected server failure", http.StatusInternalServerError)
	case "302":
		w.Header().Set("Location", "http://example.invalid/forbidden-redirect")
		w.WriteHeader(http.StatusFound)
	case "drop":
		hijacker, ok := w.(http.Hijacker)
		if !ok {
			http.Error(w, "hijacking unavailable", http.StatusInternalServerError)
			return true
		}
		connection, _, err := hijacker.Hijack()
		if err == nil {
			_ = connection.Close()
		}
	default:
		http.Error(w, "invalid injected status", http.StatusInternalServerError)
	}
	return true
}

func pauseAtPhase(environmentName string) {
	if os.Getenv(environmentName) != "1" {
		return
	}
	marker := os.Getenv("FAKE_PHASE_MARKER")
	if marker == "" {
		panic("FAKE_PHASE_MARKER is required for a paused phase")
	}
	if err := os.WriteFile(marker, []byte(environmentName), 0o600); err != nil {
		panic(err)
	}
	time.Sleep(10 * time.Second)
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: consul-handoff-server PORT")
		os.Exit(2)
	}
	port := os.Args[1]
	statePath := os.Getenv("FAKE_CONSUL_STATE")
	oldToken := os.Getenv("FAKE_OLD_TOKEN")
	candidateToken := os.Getenv("FAKE_CANDIDATE_TOKEN")
	unregisteredToken := os.Getenv("FAKE_UNREGISTERED_TOKEN")
	if statePath == "" || oldToken == "" || candidateToken == "" || unregisteredToken == "" {
		panic("fake Consul server environment is incomplete")
	}

	const oldAccessor = "11111111-1111-4111-8111-111111111111"
	const candidateAccessor = "22222222-2222-4222-8222-222222222222"
	const preexistingAccessor = "44444444-4444-4444-8444-444444444444"

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		stateMu.Lock()
		defer stateMu.Unlock()
		current, err := readState(statePath)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		token := r.Header.Get("X-Consul-Token")
		authorizedManagement := (token == oldToken && current.OldValid) || (token == candidateToken && current.CandidateValid)
		w.Header().Set("Content-Type", "application/json")

		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/status/leader":
			_, _ = io.WriteString(w, `"127.0.0.1:8300"`)
		case r.Method == http.MethodGet && r.URL.Path == "/v1/acl/token/self":
			switch {
			case token == oldToken && current.OldValid:
				writeJSON(w, tokenDocument(oldAccessor, "Bootstrap Token (Global Management)", false, false))
			case token == candidateToken && current.CandidateValid && os.Getenv("FAKE_FAIL_CANDIDATE_SELF") != "1":
				if injectedHTTP(w, os.Getenv("FAKE_CANDIDATE_SELF_STATUS")) {
					return
				}
				writeJSON(w, tokenDocument(candidateAccessor, "E2B Consul promoted management token", true, false))
			case token == oldToken && !current.OldValid:
				if injectedHTTP(w, os.Getenv("FAKE_OLD_REPLAY_STATUS")) {
					return
				}
				http.Error(w, "permission denied", http.StatusForbidden)
			case token == unregisteredToken:
				if injectedHTTP(w, os.Getenv("FAKE_UNREGISTERED_STATUS")) {
					return
				}
				http.Error(w, "permission denied", http.StatusForbidden)
			default:
				http.Error(w, "permission denied", http.StatusForbidden)
			}
		case r.Method == http.MethodPut && r.URL.Path == "/v1/acl/token":
			if !authorizedManagement {
				http.Error(w, "permission denied", http.StatusForbidden)
				return
			}
			var payload struct {
				SecretID string `json:"SecretID"`
			}
			if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&payload); err != nil || payload.SecretID != candidateToken {
				http.Error(w, "invalid candidate", http.StatusBadRequest)
				return
			}
			pauseAtPhase("FAKE_PAUSE_CANDIDATE_CREATE")
			current.CandidateValid = true
			if err := writeState(statePath, current); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			if injectedHTTP(w, os.Getenv("FAKE_CANDIDATE_CREATE_STATUS")) {
				return
			}
			response := tokenDocument(candidateAccessor, "E2B Consul promoted management token", true, false)
			response["SecretID"] = candidateToken
			writeJSON(w, response)
		case r.Method == http.MethodGet && r.URL.Path == "/v1/acl/tokens":
			if !authorizedManagement {
				http.Error(w, "permission denied", http.StatusForbidden)
				return
			}
			tokens := make([]any, 0, 3)
			if current.OldValid {
				tokens = append(tokens, tokenDocument(oldAccessor, "Bootstrap Token (Global Management)", false, false))
			}
			if current.CandidateValid {
				tokens = append(tokens, tokenDocument(candidateAccessor, "E2B Consul promoted management token", true, false))
			}
			if current.PreexistingValid {
				tokens = append(tokens, tokenDocument(preexistingAccessor, "E2B Consul promoted management token", true, false))
			}
			if kind := os.Getenv("FAKE_EXTRA_AUTHORITY_KIND"); kind != "" {
				tokens = append(tokens, extraAuthorityDocument(kind, false))
			}
			writeJSON(w, tokens)
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/acl/token/"):
			if !authorizedManagement {
				http.Error(w, "permission denied", http.StatusForbidden)
				return
			}
			accessor := strings.TrimPrefix(r.URL.Path, "/v1/acl/token/")
			expanded := r.URL.Query().Get("expanded") == "true"
			switch {
			case accessor == oldAccessor && current.OldValid:
				pauseAtPhase("FAKE_PAUSE_LEGACY_ACCESSOR_GET")
				writeJSON(w, tokenDocument(oldAccessor, "Bootstrap Token (Global Management)", false, expanded))
			case accessor == candidateAccessor && current.CandidateValid:
				writeJSON(w, tokenDocument(candidateAccessor, "E2B Consul promoted management token", true, expanded))
			case accessor == preexistingAccessor && current.PreexistingValid:
				writeJSON(w, tokenDocument(preexistingAccessor, "E2B Consul promoted management token", true, expanded))
			case accessor == "33333333-3333-4333-8333-333333333333" && os.Getenv("FAKE_EXTRA_AUTHORITY_KIND") != "":
				writeJSON(w, extraAuthorityDocument(os.Getenv("FAKE_EXTRA_AUTHORITY_KIND"), expanded))
			default:
				http.NotFound(w, r)
			}
		case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/v1/acl/token/"):
			if !authorizedManagement {
				http.Error(w, "permission denied", http.StatusForbidden)
				return
			}
			accessor := strings.TrimPrefix(r.URL.Path, "/v1/acl/token/")
			switch accessor {
			case oldAccessor:
				if os.Getenv("FAKE_FAIL_OLD_DELETE") == "1" {
					http.Error(w, "injected old-token deletion failure", http.StatusInternalServerError)
					return
				}
				current.OldValid = false
			case candidateAccessor:
				if os.Getenv("FAKE_FAIL_CANDIDATE_DELETE") == "1" {
					http.Error(w, "injected candidate-token deletion failure", http.StatusInternalServerError)
					return
				}
				current.CandidateValid = false
			case preexistingAccessor:
				current.PreexistingValid = false
			default:
				http.NotFound(w, r)
				return
			}
			if err := writeState(statePath, current); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			_, _ = io.WriteString(w, `true`)
		case r.URL.Path == "/v1/kv/e2b/acl-lineage/management" && r.Method == http.MethodGet:
			if !authorizedManagement {
				http.Error(w, "permission denied", http.StatusForbidden)
				return
			}
			if len(current.Lineage) == 0 {
				http.NotFound(w, r)
				return
			}
			if _, raw := r.URL.Query()["raw"]; raw {
				if os.Getenv("FAKE_CORRUPT_PENDING_READBACK") == "1" && strings.Contains(string(current.Lineage), `"handoff_pending_accessor"`) {
					_, _ = io.WriteString(w, `{"corrupt":"pending"}`)
					return
				}
				if os.Getenv("FAKE_CORRUPT_FINAL_READBACK") == "1" && strings.Contains(string(current.Lineage), `"last_revoked_accessor"`) {
					_, _ = io.WriteString(w, `{"corrupt":"final"}`)
					return
				}
				_, _ = w.Write(current.Lineage)
				return
			}
			encoded := base64.StdEncoding.EncodeToString(current.Lineage)
			_, _ = io.WriteString(w, `[{"Key":"e2b/acl-lineage/management","ModifyIndex":`+strconv.FormatUint(current.LineageModifyIndex, 10)+`,"Value":"`+encoded+`"}]`)
		case r.URL.Path == "/v1/kv/e2b/acl-lineage/management" && r.Method == http.MethodPut:
			if !authorizedManagement {
				http.Error(w, "permission denied", http.StatusForbidden)
				return
			}
			body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
			if err != nil || !json.Valid(body) {
				http.Error(w, "invalid lineage", http.StatusBadRequest)
				return
			}
			if os.Getenv("FAKE_FAIL_FINAL_LINEAGE") == "1" && strings.Contains(string(body), `"last_revoked_accessor"`) {
				http.Error(w, "injected final-lineage failure", http.StatusInternalServerError)
				return
			}
			if strings.Contains(string(body), `"last_revoked_accessor"`) {
				pauseAtPhase("FAKE_PAUSE_FINAL_LINEAGE")
			}
			if casValue := r.URL.Query().Get("cas"); casValue != "" {
				expected, err := strconv.ParseUint(casValue, 10, 64)
				if err != nil {
					http.Error(w, "invalid cas", http.StatusBadRequest)
					return
				}
				currentIndex := current.LineageModifyIndex
				if len(current.Lineage) == 0 {
					currentIndex = 0
				}
				if expected != currentIndex {
					_, _ = io.WriteString(w, `false`)
					return
				}
			}
			current.Lineage = append(json.RawMessage(nil), body...)
			current.LineageModifyIndex++
			if current.LineageModifyIndex == 0 {
				current.LineageModifyIndex = 1
			}
			if err := writeState(statePath, current); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			_, _ = io.WriteString(w, `true`)
		case r.URL.Path == "/v1/kv/e2b/acl-lineage/management" && r.Method == http.MethodDelete:
			if !authorizedManagement {
				http.Error(w, "permission denied", http.StatusForbidden)
				return
			}
			if os.Getenv("FAKE_FAIL_LINEAGE_ROLLBACK") == "1" && r.URL.Query().Get("cas") != "" {
				http.Error(w, "injected lineage rollback failure", http.StatusInternalServerError)
				return
			}
			if casValue := r.URL.Query().Get("cas"); casValue != "" {
				expected, err := strconv.ParseUint(casValue, 10, 64)
				if err != nil || len(current.Lineage) == 0 || expected != current.LineageModifyIndex {
					_, _ = io.WriteString(w, `false`)
					return
				}
			}
			current.Lineage = nil
			current.LineageModifyIndex = 0
			if err := writeState(statePath, current); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			_, _ = io.WriteString(w, `true`)
		default:
			http.NotFound(w, r)
		}
	})

	if err := http.ListenAndServe("127.0.0.1:"+port, handler); err != nil {
		panic(err)
	}
}
