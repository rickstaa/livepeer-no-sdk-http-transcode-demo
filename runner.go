// Smallest PUT runner: PUT /in feeds ffmpeg, GET /out returns a 720p + 360p ladder.
// A demo only: it never removes finished sessions or handles dropped connections.
package main

import (
	"io"
	"net/http"
	"os"
	"os/exec"
	"sync"
)

// job is one session's ffmpeg process.
type job struct {
	in  io.WriteCloser
	out io.Reader
}

var (
	mu   sync.Mutex
	jobs = map[string]*job{}
)

// session links the PUT and the GET: the orchestrator adds the same session ID
// to both requests, so whichever arrives first starts ffmpeg.
func session(r *http.Request) *job {
	mu.Lock()
	defer mu.Unlock()
	id := r.Header.Get("Livepeer-Session-Id")
	if jobs[id] == nil {
		cmd := exec.Command("ffmpeg", "-loglevel", "error", "-i", "pipe:0", "-map", "0:v", "-map", "0:v",
			"-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
			"-s:v:0", "1280x720", "-s:v:1", "640x360", "-f", "matroska", "pipe:1")
		cmd.Stderr = os.Stderr
		in, _ := cmd.StdinPipe()
		out, _ := cmd.StdoutPipe()
		_ = cmd.Start()
		jobs[id] = &job{in, out}
	}
	return jobs[id]
}

func main() {
	// Source goes in: copy the upload into ffmpeg until the client finishes.
	http.HandleFunc("PUT /in", func(w http.ResponseWriter, r *http.Request) {
		j := session(r)
		_, _ = io.Copy(j.in, r.Body)
		_ = j.in.Close() // ffmpeg drains, then ends GET /out.
	})
	// Renditions come out: flush each read so the client gets them live.
	http.HandleFunc("GET /out", func(w http.ResponseWriter, r *http.Request) {
		j, buf := session(r), make([]byte, 32<<10)
		for {
			n, err := j.out.Read(buf)
			_, _ = w.Write(buf[:n])
			w.(http.Flusher).Flush()
			if err != nil {
				return
			}
		}
	})
	_ = http.ListenAndServe("127.0.0.1:9000", nil)
}
