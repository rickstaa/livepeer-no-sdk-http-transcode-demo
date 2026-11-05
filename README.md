# Transcoding over HTTP PUT and GET

Shows that a transcoding runner works on an unmodified `livepeer/node`
orchestrator using plain HTTP. The client uploads a stream with PUT and downloads
an ABR ladder with GET. It needs no SDK and no trickle.

## Run it

Requires Go, `ffmpeg` with libx264, `curl`, `jq`, and a `livepeer/node` checkout
at `../node` (or set `NODE_DIR`). Ports 8935, 8936 and 9000 must be free.

```sh
./run.sh        # MKV upload
./run.sh fmp4   # fragmented MP4 upload
```

`out.mkv` ends up with two video tracks, 720p and 360p, with 240 frames each.

## How it works

PUT and GET are two separate HTTP requests. Only the session ID links them.

```text
                     orchestrator                runner
client               (forwards HTTP)             (runner.go + ffmpeg)

POST /apps/transcode/session
  ---------------->  returns app_url

PUT {app_url}/in     PUT /in
  ================>  =======================>    body -> ffmpeg stdin
                                                          |
GET {app_url}/out    GET /out                             v
  <================  <=======================    response <- ffmpeg stdout

POST {control_url}/stop
  ---------------->  releases the session
```

1. **Reserve:** `POST /apps/transcode/session` returns `app_url`, the session's
   route to the runner, and `control_url`.
2. **PUT:** the orchestrator replaces the `app_url` prefix with `RunnerURL`, so
   `{app_url}/in` reaches the runner as `/in`. It adds `Livepeer-Session-Id` and
   stays open for the whole stream, passing chunks on as they arrive. The runner
   pipes the body into ffmpeg's stdin.
3. **GET:** this request carries the same session ID, so the runner finds the same
   ffmpeg and streams its stdout back. Both the runner and the orchestrator flush
   as data arrives, so renditions come back while the upload is still running.
4. **End:** when the upload ends, the runner closes ffmpeg's stdin. ffmpeg drains
   and exits, which ends the GET. The client then releases the session.

The orchestrator knows nothing about video. It sees two long-running HTTP requests
and doesn't parse the bytes, so the runner defines the paths and formats.

## On a paid network

This demo runs offchain, and this flow hasn't been run without the SDK. The runner
and the PUT and GET requests stay the same.

**Orchestrator:** set `Network`, a keystore, an RPC URL, ticket parameters and a
runner price. See `docs/orchestrator.md` in `livepeer/node`.

**Client:** run a signer whose payer has deposit and reserve, then:

1. Get the payer address from the signer's `POST /sign-orchestrator-info`.
2. `POST /apps/{id}/session` with `Livepeer-Payer-Address`. It returns a 402 challenge.
3. Call the signer's `POST /generate-live-payment` with the challenge's
   `payment_params` as `orchestrator` and `type` set to `live`. Keep the returned `state`.
4. Retry the session POST with `payment` as `Livepeer-Payment` and `segCreds` as
   `Livepeer-Segment`.
5. Send media as in this demo.
6. Generate more payments, passing `state` back, and send them to
   `{control_url}/payment`. The session ends if its balance runs out.
7. If the signer returns 480, call `POST /refresh-payment` with `sender` and
   `manifest_id`, then pay against the new challenge.

The SDK's `reserve_session` with `signer_url` handles the session and payment steps.
ffmpeg can still send the media to `app_url`, as long as the Python process keeps running.

## Limits

- It ran offchain, over plain HTTP on loopback, without MistServer. HTTPS depends on
  the orchestrator's reverse proxy not buffering requests.
- The runner is a demo. It never removes finished sessions or handles dropped
  connections.
- A dropped PUT can't resume. Use one PUT per segment if you need that.
- The runner must send GET response headers within 60 seconds or the orchestrator
  returns 502. Each open request also holds one of the orchestrator's 256 streaming
  slots.
- Both renditions share one GET as tracks in one MKV. Separate renditions would each
  need their own GET and slot.
- The orchestrator logs `runner proxy failed` after each ffmpeg upload, even though
  all the data arrives. ffmpeg likely closes the connection without waiting for the
  response.
