# Transcriber

Upload an audio or video file → WhisperX transcribes and diarizes it → assign names to speakers → download a subtitled MP4.

---

## How it works

1. **Upload** — drop a file (up to 2 GB). Dropzone.js sends it in 50 MB chunks.
2. **Transcribe** — WhisperX runs in the background; the browser polls for status.
3. **Identify speakers** — listen to a clip from each detected speaker and type their name.
4. **Render** — ffmpeg burns the named subtitles into the video.
5. **Download** — grab the finished MP4. Use the Back button to re-render with different names.

Jobs persist on disk for one week (configurable), so you can close the browser and return via the URL.

---

## Prerequisites

| Tool | Version |
|---|---|
| Python | 3.11+ |
| ffmpeg | any recent (tested with 4.4) |
| Docker + nvidia-docker | for containerised run |

---

## Configuration

Copy `.env.example` to `.env` and edit as needed:

```sh
cp .env.example .env
```

Key variables:

| Variable | Default | Description |
|---|---|---|
| `FLASK_SECRET_KEY` | *(required)* | Flask session secret — change in production |
| `WHISPERX_CMD` | `whisperx "{input}" --model large-v2 --diarize --highlight_words True --min_speakers 2 --max_speakers 10 --output_dir "{output_dir}"` |
| `FFMPEG_CMD` | `ffmpeg -y -i "{input}" -i "{srt}" -c:a aac -c:s mov_text -f lavfi -i color=c=black:s=1280x720 -vf "subtitles={srt}" -c:v libx264 -crf 23 -shortest "{output}"` |
| `JOB_TTL_SECONDS` | `604800` | Job expiry (seconds). Default: 1 week |
| `SPEAKER_CLIP_MAX_SECONDS` | `10` | Max length of speaker identification clips |
| `MAX_UPLOAD_BYTES` | `2147483648` | 2 GB upload limit |

---

## Run environments

### 1. Python virtualenv (development)

```sh
# Create and activate virtualenv
python3 -m venv .venv
source .venv/bin/activate       # Windows: .venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Copy and edit config
cp .env.example .env

# Run
python run.py
```

App available at http://localhost:5000

---

### 2. Docker (single container)

```sh
# Build
docker build -t transcriber .

# Run
docker run \
  --gpus all \
  -p 80:80 \
  --env-file .env \
  -v $(pwd)/storage:/app/storage \
  transcriber
```

App available at http://localhost

---

### 3. Docker Compose

```sh
# Build and start
docker-compose up --build

# Start in background
docker-compose up -d --build

# View logs
docker-compose logs -f

# Stop
docker-compose down
```

App available at http://localhost

---

## Project structure

```
transcriber/
├── app.py                  Flask application factory
├── config.py               Central config — reads .env
├── models.py               Job dataclass + JobStatus enum
├── run.py                  Dev entry point (python run.py)
│
├── routes/
│   ├── upload.py           Chunked upload + job creation
│   ├── job.py              Status polling + speaker endpoints
│   ├── processing.py       Back-navigation (reset to AWAITING_NAMES)
│   └── download.py         Download page + file serving
│
├── jobs/
│   ├── manager.py          JobManager — create/get/update/submit_task
│   └── runner.py           Background tasks: run_transcription, run_render
│
├── services/
│   ├── whisperx.py         WhisperX subprocess wrapper
│   ├── srt_parser.py       Parse WhisperX SRT, apply speaker names
│   ├── audio_clip.py       Extract speaker WAV clips via ffmpeg
│   └── ffmpeg.py           Subtitle burn-in render via ffmpeg
│
├── tasks/
│   └── expiry.py           Hourly job expiry sweep
│
├── templates/
│   ├── base.html
│   ├── upload.html
│   ├── processing.html
│   ├── speakers.html
│   └── download.html
│
├── nginx/nginx.conf
├── supervisord.conf
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
├── .env.example
└── storage/                Job data (git-ignored)
    └── tmp/                Chunk staging area
```

---

## Celery upgrade path

Today, background tasks run in daemon threads. To switch to Celery, change **only** `JobManager.submit_task()` in `jobs/manager.py`:

```python
# Today (threading — one method body to replace):
def submit_task(self, job_id, task_fn, *args):
    threading.Thread(target=self._run_task, args=(job_id, task_fn, *args), daemon=True).start()

# Celery (future):
def submit_task(self, job_id, task_fn, *args):
    celery_task.delay(job_id, *args)
```

No other files need to change.

---

## Job state machine

```
UPLOADING → TRANSCRIBING → AWAITING_NAMES → RENDERING → DONE
                                  ↑________________________________|
                                         (back button resets here)
```

Failed jobs land in `FAILED` status with an `error` field containing the traceback.

---

## WhisperX SRT format

WhisperX outputs speaker labels as `[SPEAKER_00]:` prefixes on subtitle lines:

```
1
00:00:01,000 --> 00:00:04,500
[SPEAKER_00]: Hello, welcome to the show.
```

`srt_parser.py` handles this format for both parsing and name replacement.
