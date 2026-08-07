package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: nomad-request-capture CAPTURE_FILE PORT_FILE")
		os.Exit(2)
	}

	capturePath := os.Args[1]
	portPath := os.Args[2]
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	defer listener.Close()

	port := listener.Addr().(*net.TCPAddr).Port
	if err := os.WriteFile(portPath, []byte(fmt.Sprintf("%d\n", port)), 0o600); err != nil {
		panic(err)
	}

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(os.Stderr, "%s %s\n", r.Method, r.URL.RequestURI())
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Nomad-Index", "1")

		switch {
		case r.Method == http.MethodPut && strings.HasPrefix(r.URL.Path, "/v1/job/") && strings.HasSuffix(r.URL.Path, "/plan"):
			_, _ = io.WriteString(w, `{"JobModifyIndex":0,"CreatedEvals":[],"FailedTGAllocs":{},"Warnings":""}`)
		case r.Method == http.MethodPut && r.URL.Path == "/v1/jobs":
			body, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			if err := os.WriteFile(capturePath, body, 0o600); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			_, _ = io.WriteString(w, `{"EvalID":"","EvalCreateIndex":1,"JobModifyIndex":1,"Warnings":""}`)
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/job/") && strings.HasSuffix(r.URL.Path, "/submission"):
			http.NotFound(w, r)
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/job/"):
			jobID := strings.TrimPrefix(r.URL.Path, "/v1/job/")
			_, _ = fmt.Fprintf(w, `{"ID":%q,"Name":%q,"Type":"batch","Region":"global","Datacenters":["dc1"],"Namespace":"default","TaskGroups":[],"JobModifyIndex":1,"Version":0,"Status":"running"}`, jobID, jobID)
		default:
			http.NotFound(w, r)
		}
	})

	server := &http.Server{Handler: handler}
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		panic(err)
	}
}
