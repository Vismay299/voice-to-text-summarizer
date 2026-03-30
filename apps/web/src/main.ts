import type {
  CaptureMode,
  FinalSummary,
  ExperimentalGoogleMeetResponse,
  ExperimentalGoogleMeetState,
  MeetingHelperResponse,
  MeetingSurface,
  MeetingSupportStatus,
  SessionArchiveEntry,
  SessionArchiveListResponse,
  SessionArchiveResponse,
  SessionError,
  SessionRecord,
  SessionStartResponse,
  SessionStatusResponse,
  SessionStopResponse,
  RuntimeId,
  RuntimeConfigResponse,
  LiveNotesResponse,
  TranscriptResponse,
  SummaryResponse,
  StartSessionRequest,
  StopSessionRequest,
  UpdateRuntimeConfigRequest,
  UpdateRuntimeConfigResponse,
  UpdateMeetingHelperRequest,
  UpdateMeetingHelperResponse,
  UpdateExperimentalGoogleMeetRequest,
  UpdateExperimentalGoogleMeetResponse
} from "@voice/shared";
import { BRIDGE_COMMANDS, CAPTURE_MODES, DEFAULT_LANGUAGE, DEFAULT_RUNTIME_CONFIG, MEETING_SURFACES } from "@voice/shared";
import "./style.css";

const app = document.querySelector<HTMLDivElement>("#app");
const companionBaseUrl = "http://localhost:4545";

if (!app) {
  throw new Error("App root not found");
}

app.innerHTML = `
  <main class="shell">
    <section class="hero">
      <p class="eyebrow">Voice-to-Text Summarizer</p>
      <h1>Capture the call. Keep the conversation. Get the summary.</h1>
      <p class="lede">
        Web-first control surface for a local desktop companion that turns live conversations into notes and summaries.
      </p>
      <div class="pill-row">
        <span>TypeScript</span>
        <span>Local bridge</span>
        <span>Open-source models</span>
      </div>
    </section>

    <section class="grid">
      <article class="card">
        <h2>Runtime Config</h2>
        <p>Choose a local runtime and keep English as the default launch language.</p>
        <div class="status">
          <strong>Current runtime</strong>
          <span id="selected-runtime">Checking companion...</span>
        </div>
        <div class="status">
          <strong>Available runtimes</strong>
          <span id="runtime-options">Loading options...</span>
        </div>
        <div class="status">
          <strong>Default language</strong>
          <span id="default-language">en</span>
        </div>
        <label class="config-field">
          <span>Local runtime</span>
          <select id="runtime-id">
            <option value="">Loading...</option>
          </select>
        </label>
        <div class="button-row">
          <button id="save-runtime" type="button">Save runtime config</button>
        </div>
      </article>

      <article class="card">
        <h2>Session Controls</h2>
        <p>Start and stop a local session against the desktop companion.</p>
        <form class="session-form" id="session-form">
          <label>
            <span>Capture mode</span>
            <select id="capture-mode">
              ${CAPTURE_MODES.map((mode) => `<option value="${mode}">${mode}</option>`).join("")}
            </select>
          </label>

          <label>
            <span>Language</span>
            <input id="language" type="text" value="${DEFAULT_LANGUAGE}" readonly />
          </label>

          <label class="checkbox-row">
            <input id="save-transcript" type="checkbox" checked />
            <span>Save transcript</span>
          </label>

          <label class="checkbox-row">
            <input id="save-summary" type="checkbox" checked />
            <span>Save summary</span>
          </label>

          <div class="button-row">
            <button id="start-session" type="submit">Start session</button>
            <button id="stop-session" type="button" class="secondary">Stop session</button>
          </div>
        </form>
        <div class="status">
          <strong>Session status</strong>
          <span id="session-status">Checking companion...</span>
        </div>
        <div class="status">
          <strong>Selected mode</strong>
          <span id="selected-mode">speakerphone</span>
        </div>
        <div class="status">
          <strong>Elapsed time</strong>
          <span id="elapsed-time">00:00</span>
        </div>
      </article>

      <article class="card meeting-card">
        <h2>Meeting Helper</h2>
        <p class="transcript-note">
          Use this route for browser or desktop meetings. Google Meet falls back to the browser helper until a true bot exists.
        </p>
        <div class="transcript-metrics" aria-live="polite">
          <div class="metric">
            <strong>Route</strong>
            <span id="meeting-route">Desktop meeting</span>
          </div>
          <div class="metric">
            <strong>Status</strong>
            <span id="meeting-status">Loading...</span>
          </div>
          <div class="metric">
            <strong>Fallback</strong>
            <span id="meeting-fallback-status">None</span>
          </div>
          <div class="metric">
            <strong>Active</strong>
            <span id="meeting-active">No</span>
          </div>
        </div>
        <label class="config-field">
          <span>Meeting surface</span>
          <select id="meeting-surface">
            <option value="desktop-meeting">Desktop meeting</option>
            <option value="browser-meeting">Browser meeting</option>
            <option value="google-meet">Google Meet</option>
          </select>
        </label>
        <ul id="meeting-guidance" class="meeting-guidance">
          <li>Loading meeting helper support...</li>
        </ul>
        <div class="button-row">
          <button id="apply-meeting-helper" type="button">Apply meeting helper</button>
          <button id="meeting-fallback-button" type="button" class="secondary">Use browser fallback</button>
        </div>
      </article>

      <article class="card experimental-card">
        <h2>Experimental Google Meet</h2>
        <p class="transcript-note">
          Lab-only boundary for prototyping Google Meet routing metadata and guardrails. It does not join Meet as a bot or hidden participant.
        </p>
        <div class="transcript-metrics" aria-live="polite">
          <div class="metric">
            <strong>Flag</strong>
            <span id="experimental-google-meet-flag">Loading...</span>
          </div>
          <div class="metric">
            <strong>Boundary</strong>
            <span id="experimental-google-meet-status">Loading...</span>
          </div>
          <div class="metric">
            <strong>Availability</strong>
            <span id="experimental-google-meet-availability">Checking...</span>
          </div>
          <div class="metric">
            <strong>Active</strong>
            <span id="experimental-google-meet-active">No</span>
          </div>
        </div>
        <label class="checkbox-row">
          <input id="experimental-google-meet-enabled" type="checkbox" />
          <span>Enable lab boundary</span>
        </label>
        <div class="button-row">
          <button id="save-experimental-google-meet" type="button">Save lab state</button>
          <button id="refresh-experimental-google-meet" type="button" class="secondary">Refresh</button>
        </div>
        <p id="experimental-google-meet-error" class="transcript-note">Waiting for experimental state...</p>
        <ul id="experimental-google-meet-notes" class="meeting-guidance">
          <li>Loading experimental notes...</li>
        </ul>
      </article>

      <article class="card">
        <h2>Current Session</h2>
        <p id="session-summary">No active session yet.</p>
        <code id="session-json">Waiting for companion state...</code>
      </article>

      <article class="card transcript-card">
        <h2>Transcript Stream</h2>
        <p class="transcript-note">
          Simulated chunked transcript updates from the companion. Real STT will replace this later.
        </p>
        <div class="transcript-metrics" aria-live="polite">
          <div class="metric">
            <strong>Transcript state</strong>
            <span id="transcript-status">Idle</span>
          </div>
          <div class="metric">
            <strong>Chunks</strong>
            <span id="transcript-chunks">0</span>
          </div>
          <div class="metric">
            <strong>Revision</strong>
            <span id="transcript-revision">0</span>
          </div>
          <div class="metric">
            <strong>Last update</strong>
            <span id="transcript-updated">Never</span>
          </div>
        </div>
        <ol id="transcript-list" class="transcript-list">
          <li class="transcript-empty">No transcript chunks yet.</li>
        </ol>
      </article>

      <article class="card notes-card">
        <h2>Live Notes</h2>
        <p class="transcript-note">
          Simulated notes derived from the active transcript chunks.
        </p>
        <div class="transcript-metrics" aria-live="polite">
          <div class="metric">
            <strong>Notes state</strong>
            <span id="notes-status">Idle</span>
          </div>
          <div class="metric">
            <strong>Notes</strong>
            <span id="notes-count">0</span>
          </div>
          <div class="metric">
            <strong>Revision</strong>
            <span id="notes-revision">0</span>
          </div>
          <div class="metric">
            <strong>Last update</strong>
            <span id="notes-updated">Never</span>
          </div>
        </div>
        <ol id="notes-list" class="transcript-list">
          <li class="transcript-empty">No notes yet.</li>
        </ol>
      </article>

      <article class="card summary-card">
        <h2>Final Summary</h2>
        <p class="transcript-note">
          The summary appears after the session stops and is generated from the accumulated transcript.
        </p>
        <div class="status">
          <strong>Summary state</strong>
          <span id="summary-status">Waiting for session to complete</span>
        </div>
        <div class="summary-body">
          <p id="summary-overview">No summary yet.</p>
          <ul id="summary-points">
            <li>Stop the session to generate a summary.</li>
          </ul>
        </div>
      </article>

      <article class="card history-card">
        <h2>Session History</h2>
        <p class="transcript-note">
          Completed sessions are archived locally so they can be reviewed later.
        </p>
        <div class="transcript-metrics" aria-live="polite">
          <div class="metric">
            <strong>Archived</strong>
            <span id="history-count">0</span>
          </div>
          <div class="metric">
            <strong>Selection</strong>
            <span id="history-status">None selected</span>
          </div>
          <div class="metric">
            <strong>Storage</strong>
            <span>.voice-to-text-summarizer/sessions.json</span>
          </div>
          <div class="metric">
            <strong>State</strong>
            <span>Local only</span>
          </div>
        </div>
        <div class="history-layout">
          <ol id="history-list" class="history-list">
            <li class="transcript-empty">No archived sessions yet.</li>
          </ol>
          <div id="history-detail" class="history-detail">
            Select a completed session to inspect its transcript, notes, and summary.
          </div>
        </div>
      </article>

      <article class="card">
        <h2>Roadmap Context</h2>
        <ul>
          <li>Live notes will stream in during a session.</li>
          <li>Final summaries will be stored alongside transcripts.</li>
          <li>This feature covers session start/stop and capture-mode configuration.</li>
          <li>Runtime selection is surfaced now, with English held as the default language.</li>
        </ul>
      </article>

      <article class="card">
        <h2>Bridge Contract</h2>
        <p>Commands shared with the companion:</p>
        <code>${BRIDGE_COMMANDS.join(", ")}</code>
      </article>
    </section>
  </main>
`;

const sessionForm = document.querySelector<HTMLFormElement>("#session-form");
const runtimeSelect = document.querySelector<HTMLSelectElement>("#runtime-id");
const captureModeInput = document.querySelector<HTMLSelectElement>("#capture-mode");
const saveTranscriptInput = document.querySelector<HTMLInputElement>("#save-transcript");
const saveSummaryInput = document.querySelector<HTMLInputElement>("#save-summary");
const saveRuntimeButton = document.querySelector<HTMLButtonElement>("#save-runtime");
const sessionStatusLabel = document.querySelector<HTMLElement>("#session-status");
const selectedRuntimeLabel = document.querySelector<HTMLElement>("#selected-runtime");
const runtimeOptionsLabel = document.querySelector<HTMLElement>("#runtime-options");
const defaultLanguageLabel = document.querySelector<HTMLElement>("#default-language");
const selectedModeLabel = document.querySelector<HTMLElement>("#selected-mode");
const elapsedTimeLabel = document.querySelector<HTMLElement>("#elapsed-time");
const sessionSummaryLabel = document.querySelector<HTMLElement>("#session-summary");
const sessionJsonOutput = document.querySelector<HTMLElement>("#session-json");
const transcriptStatusLabel = document.querySelector<HTMLElement>("#transcript-status");
const transcriptChunkCountLabel = document.querySelector<HTMLElement>("#transcript-chunks");
const transcriptRevisionLabel = document.querySelector<HTMLElement>("#transcript-revision");
const transcriptUpdatedLabel = document.querySelector<HTMLElement>("#transcript-updated");
const transcriptList = document.querySelector<HTMLOListElement>("#transcript-list");
const notesStatusLabel = document.querySelector<HTMLElement>("#notes-status");
const notesCountLabel = document.querySelector<HTMLElement>("#notes-count");
const notesRevisionLabel = document.querySelector<HTMLElement>("#notes-revision");
const notesUpdatedLabel = document.querySelector<HTMLElement>("#notes-updated");
const notesList = document.querySelector<HTMLOListElement>("#notes-list");
const meetingRouteLabel = document.querySelector<HTMLElement>("#meeting-route");
const meetingStatusLabel = document.querySelector<HTMLElement>("#meeting-status");
const meetingFallbackStatusLabel = document.querySelector<HTMLElement>("#meeting-fallback-status");
const meetingActiveLabel = document.querySelector<HTMLElement>("#meeting-active");
const meetingSurfaceSelect = document.querySelector<HTMLSelectElement>("#meeting-surface");
const meetingGuidanceList = document.querySelector<HTMLUListElement>("#meeting-guidance");
const applyMeetingHelperButton = document.querySelector<HTMLButtonElement>("#apply-meeting-helper");
const meetingFallbackButton = document.querySelector<HTMLButtonElement>("#meeting-fallback-button");
const experimentalGoogleMeetFlagLabel = document.querySelector<HTMLElement>("#experimental-google-meet-flag");
const experimentalGoogleMeetStatusLabel = document.querySelector<HTMLElement>("#experimental-google-meet-status");
const experimentalGoogleMeetAvailabilityLabel = document.querySelector<HTMLElement>("#experimental-google-meet-availability");
const experimentalGoogleMeetActiveLabel = document.querySelector<HTMLElement>("#experimental-google-meet-active");
const experimentalGoogleMeetEnabledInput = document.querySelector<HTMLInputElement>("#experimental-google-meet-enabled");
const saveExperimentalGoogleMeetButton = document.querySelector<HTMLButtonElement>("#save-experimental-google-meet");
const refreshExperimentalGoogleMeetButton = document.querySelector<HTMLButtonElement>("#refresh-experimental-google-meet");
const experimentalGoogleMeetError = document.querySelector<HTMLElement>("#experimental-google-meet-error");
const experimentalGoogleMeetNotes = document.querySelector<HTMLUListElement>("#experimental-google-meet-notes");
const summaryStatusLabel = document.querySelector<HTMLElement>("#summary-status");
const summaryOverviewLabel = document.querySelector<HTMLElement>("#summary-overview");
const summaryPointsList = document.querySelector<HTMLUListElement>("#summary-points");
const historyCountLabel = document.querySelector<HTMLElement>("#history-count");
const historyStatusLabel = document.querySelector<HTMLElement>("#history-status");
const historyList = document.querySelector<HTMLOListElement>("#history-list");
const historyDetail = document.querySelector<HTMLElement>("#history-detail");
const stopSessionButton = document.querySelector<HTMLButtonElement>("#stop-session");
const startSessionButton = document.querySelector<HTMLButtonElement>("#start-session");

if (
  !sessionForm ||
  !runtimeSelect ||
  !captureModeInput ||
  !saveTranscriptInput ||
  !saveSummaryInput ||
  !saveRuntimeButton ||
  !sessionStatusLabel ||
  !selectedRuntimeLabel ||
  !runtimeOptionsLabel ||
  !defaultLanguageLabel ||
  !selectedModeLabel ||
  !elapsedTimeLabel ||
  !sessionSummaryLabel ||
  !sessionJsonOutput ||
  !transcriptStatusLabel ||
  !transcriptChunkCountLabel ||
  !transcriptRevisionLabel ||
  !transcriptUpdatedLabel ||
  !transcriptList ||
  !notesStatusLabel ||
  !notesCountLabel ||
  !notesRevisionLabel ||
  !notesUpdatedLabel ||
  !notesList ||
  !meetingRouteLabel ||
  !meetingStatusLabel ||
  !meetingFallbackStatusLabel ||
  !meetingActiveLabel ||
  !meetingSurfaceSelect ||
  !meetingGuidanceList ||
  !applyMeetingHelperButton ||
  !meetingFallbackButton ||
  !experimentalGoogleMeetFlagLabel ||
  !experimentalGoogleMeetStatusLabel ||
  !experimentalGoogleMeetAvailabilityLabel ||
  !experimentalGoogleMeetActiveLabel ||
  !experimentalGoogleMeetEnabledInput ||
  !saveExperimentalGoogleMeetButton ||
  !refreshExperimentalGoogleMeetButton ||
  !experimentalGoogleMeetError ||
  !experimentalGoogleMeetNotes ||
  !summaryStatusLabel ||
  !summaryOverviewLabel ||
  !summaryPointsList ||
  !historyCountLabel ||
  !historyStatusLabel ||
  !historyList ||
  !historyDetail ||
  !stopSessionButton ||
  !startSessionButton
) {
  throw new Error("Session controls failed to initialize");
}

const statusLabel = sessionStatusLabel;
const runtimeSelectEl = runtimeSelect;
const saveTranscriptEl = saveTranscriptInput;
const saveSummaryEl = saveSummaryInput;
const saveRuntimeEl = saveRuntimeButton;
const selectedRuntimeDisplay = selectedRuntimeLabel;
const runtimeOptionsDisplay = runtimeOptionsLabel;
const defaultLanguageDisplay = defaultLanguageLabel;
const selectedModeDisplay = selectedModeLabel;
const elapsedLabel = elapsedTimeLabel;
const summaryLabel = sessionSummaryLabel;
const sessionJson = sessionJsonOutput;
const transcriptStatus = transcriptStatusLabel;
const transcriptChunkCount = transcriptChunkCountLabel;
const transcriptRevisionDisplay = transcriptRevisionLabel;
const transcriptUpdated = transcriptUpdatedLabel;
const transcriptListEl = transcriptList;
const notesStatus = notesStatusLabel;
const notesCount = notesCountLabel;
const notesRevisionDisplay = notesRevisionLabel;
const notesUpdated = notesUpdatedLabel;
const notesListEl = notesList;
const meetingRoute = meetingRouteLabel;
const meetingStatus = meetingStatusLabel;
const meetingFallbackStatus = meetingFallbackStatusLabel;
const meetingActive = meetingActiveLabel;
const meetingSurface = meetingSurfaceSelect;
const meetingGuidance = meetingGuidanceList;
const applyMeetingHelper = applyMeetingHelperButton;
const meetingFallback = meetingFallbackButton;
const experimentalGoogleMeetFlag = experimentalGoogleMeetFlagLabel;
const experimentalGoogleMeetStatus = experimentalGoogleMeetStatusLabel;
const experimentalGoogleMeetAvailability = experimentalGoogleMeetAvailabilityLabel;
const experimentalGoogleMeetActive = experimentalGoogleMeetActiveLabel;
const experimentalGoogleMeetEnabled = experimentalGoogleMeetEnabledInput;
const saveExperimentalGoogleMeetButtonEl = saveExperimentalGoogleMeetButton;
const refreshExperimentalGoogleMeetButtonEl = refreshExperimentalGoogleMeetButton;
const experimentalGoogleMeetErrorLabel = experimentalGoogleMeetError;
const experimentalGoogleMeetNotesList = experimentalGoogleMeetNotes;
const summaryStatus = summaryStatusLabel;
const summaryOverview = summaryOverviewLabel;
const summaryPoints = summaryPointsList;
const historyCount = historyCountLabel;
const historyStatus = historyStatusLabel;
const historyListEl = historyList;
const historyDetailEl = historyDetail;
const stopButton = stopSessionButton;
const startButton = startSessionButton;

let currentSession: SessionRecord | null = null;
let transcriptSegments: TranscriptResponse["transcript"]["segments"] = [];
let transcriptRevision = 0;
let notesRevision = 0;
let transcriptTimerId: number | null = null;
let notesTimerId: number | null = null;
let elapsedTimerId: number | null = null;
let elapsedSeconds = 0;
let selectedMode: CaptureMode = CAPTURE_MODES[0];
let selectedRuntimeId: RuntimeId = DEFAULT_RUNTIME_CONFIG.runtimeId;
let defaultLanguage = DEFAULT_LANGUAGE;
let runtimeOptions: RuntimeConfigResponse["config"]["options"] = [];
let currentSummary: FinalSummary | null = null;
let archivedSessions: SessionArchiveEntry[] = [];
let selectedArchiveSessionId: string | null = null;
let meetingHelperState: MeetingHelperResponse["meetingHelper"] | null = null;
let selectedMeetingSurface: MeetingSurface = "desktop-meeting";

function formatElapsedTime(seconds: number) {
  const minutes = Math.floor(seconds / 60)
    .toString()
    .padStart(2, "0");
  const remainingSeconds = (seconds % 60).toString().padStart(2, "0");
  return `${minutes}:${remainingSeconds}`;
}

function syncElapsedTime(session: SessionRecord | null) {
  if (!session || session.status !== "recording") {
    elapsedSeconds = session?.endedAt
      ? Math.max(0, Math.floor((new Date(session.endedAt).getTime() - new Date(session.startedAt).getTime()) / 1000))
      : 0;
    elapsedLabel.textContent = formatElapsedTime(elapsedSeconds);
    return;
  }

  elapsedSeconds = Math.max(0, Math.floor((Date.now() - new Date(session.startedAt).getTime()) / 1000));
  elapsedLabel.textContent = formatElapsedTime(elapsedSeconds);
}

function stopElapsedTimer() {
  if (elapsedTimerId !== null) {
    window.clearInterval(elapsedTimerId);
    elapsedTimerId = null;
  }
}

function startElapsedTimer() {
  stopElapsedTimer();
  elapsedTimerId = window.setInterval(() => {
    if (!currentSession || currentSession.status !== "recording") {
      stopElapsedTimer();
      return;
    }

    syncElapsedTime(currentSession);
  }, 1000);
}

function renderSession(session: SessionRecord | null) {
  currentSession = session;

  if (!session) {
    statusLabel.textContent = "Idle";
    selectedModeDisplay.textContent = selectedMode;
    summaryLabel.textContent = "No active session yet.";
    sessionJson.textContent = "Waiting for companion state...";
    syncElapsedTime(null);
    stopElapsedTimer();
    stopButton.disabled = true;
    startButton.disabled = false;
    return;
  }

  statusLabel.textContent = `${session.status} • ${session.sourceType}`;
  selectedModeDisplay.textContent = session.sourceType;
  const meetingRoute = session.meetingSurface ? ` using ${formatMeetingSurface(session.meetingSurface)}` : "";
  summaryLabel.textContent = `Session ${session.id} started at ${new Date(session.startedAt).toLocaleTimeString()}.${meetingRoute}`;
  sessionJson.textContent = JSON.stringify(session, null, 2);
  syncElapsedTime(session);
  if (session.status === "recording") {
    startElapsedTimer();
  } else {
    stopElapsedTimer();
  }
  startButton.disabled = session.status === "recording";
  stopButton.disabled = session.status !== "recording";
}

function renderError(message: string) {
  statusLabel.textContent = "Error";
  summaryLabel.textContent = message;
  elapsedLabel.textContent = formatElapsedTime(elapsedSeconds);
}

function formatRelativeTimestamp(isoTimestamp: string | null) {
  if (!isoTimestamp) {
    return "Never";
  }

  const elapsedMs = Date.now() - new Date(isoTimestamp).getTime();
  if (!Number.isFinite(elapsedMs) || elapsedMs < 0) {
    return "Just now";
  }

  const elapsedSeconds = Math.floor(elapsedMs / 1000);
  if (elapsedSeconds < 5) {
    return "Just now";
  }
  if (elapsedSeconds < 60) {
    return `${elapsedSeconds}s ago`;
  }

  const elapsedMinutes = Math.floor(elapsedSeconds / 60);
  if (elapsedMinutes < 60) {
    return `${elapsedMinutes}m ago`;
  }

  return new Date(isoTimestamp).toLocaleTimeString();
}

function formatMeetingSurface(surface: MeetingSurface) {
  switch (surface) {
    case "desktop-meeting":
      return "Desktop meeting";
    case "browser-meeting":
      return "Browser meeting";
    case "google-meet":
      return "Google Meet";
  }
}

function formatMeetingSupportStatus(status: MeetingSupportStatus) {
  switch (status) {
    case "supported":
      return "Supported";
    case "fallback":
      return "Fallback";
    case "experimental":
      return "Experimental";
    case "unsupported":
      return "Unsupported";
  }
}

function formatExperimentalGoogleMeetStatus(status: ExperimentalGoogleMeetState["status"]) {
  switch (status) {
    case "blocked":
      return "Blocked";
    case "disabled":
      return "Disabled";
    case "prototype":
      return "Prototype enabled";
  }
}

function updateTranscriptMetrics(transcript: TranscriptResponse["transcript"]) {
  transcriptChunkCount.textContent = String(transcript.segmentCount);
  transcriptRevisionDisplay.textContent = String(transcript.revision);
  transcriptUpdated.textContent = formatRelativeTimestamp(transcript.updatedAt);
}

function updateNotesMetrics(notes: LiveNotesResponse["notes"]) {
  notesCount.textContent = String(notes.noteCount);
  notesRevisionDisplay.textContent = String(notes.revision);
  notesUpdated.textContent = formatRelativeTimestamp(notes.updatedAt);
}

function renderTranscriptState(message: string, segments: TranscriptResponse["transcript"]["segments"], latest = true) {
  transcriptStatus.textContent = message;
  transcriptListEl.querySelector(".transcript-empty")?.remove();

  if (segments.length === 0 && transcriptListEl.children.length === 0) {
    const emptyItem = document.createElement("li");
    emptyItem.className = "transcript-empty";
    emptyItem.textContent = "No transcript chunks yet.";
    transcriptListEl.appendChild(emptyItem);
    return;
  }

  if (segments.length === 0) {
    return;
  }

  const existingLatest = transcriptListEl.querySelector(".transcript-item--latest");
  existingLatest?.classList.remove("transcript-item--latest");

  segments.forEach((segment, index) => {
    const item = document.createElement("li");
    const timeLabel = `${Math.floor(segment.startMs / 1000)}s-${Math.floor(segment.endMs / 1000)}s`;
    item.className = "transcript-item";
    item.innerHTML = `
      <div class="transcript-meta">
        <strong>${segment.speakerLabel ?? "Speaker"}</strong>
        <span>${timeLabel}</span>
      </div>
      <p>${segment.text}</p>
    `;
    if (latest && index === segments.length - 1) {
      item.classList.add("transcript-item--latest");
    }
    transcriptListEl.appendChild(item);
  });

  const latestItem = transcriptListEl.querySelector(".transcript-item--latest");
  latestItem?.scrollIntoView({ block: "nearest", behavior: "smooth" });
}

function renderRuntimeConfig(config: RuntimeConfigResponse["config"]) {
  runtimeOptions = config.options;
  selectedRuntimeId = config.current.runtimeId;
  defaultLanguage = config.current.language;

  runtimeSelectEl.innerHTML = runtimeOptions
    .map((runtime) => `<option value="${runtime.id}">${runtime.name}</option>`)
    .join("");
  runtimeSelectEl.value = selectedRuntimeId;
  const runtimeName = runtimeOptions.find((runtime) => runtime.id === selectedRuntimeId)?.name ?? selectedRuntimeId;
  selectedRuntimeDisplay.textContent = `${runtimeName} (current)`;
  runtimeOptionsDisplay.textContent = runtimeOptions
    .map((runtime) => `${runtime.name}: ${runtime.description}`)
    .join(" • ");
  defaultLanguageDisplay.textContent = config.defaults.language.toUpperCase();
  saveTranscriptEl.checked = config.current.saveTranscript;
  saveSummaryEl.checked = config.current.saveSummary;
  runtimeSelectEl.disabled = false;
  saveRuntimeEl.disabled = false;
}

function renderMeetingHelper(state: MeetingHelperResponse["meetingHelper"]) {
  meetingHelperState = state;
  selectedMeetingSurface = state.selectedSurface;
  meetingSurface.value = state.selectedSurface;
  meetingRoute.textContent = `${formatMeetingSurface(state.effectiveSurface)}${state.selectedSurface !== state.effectiveSurface ? " (fallback applied)" : ""}`;
  meetingStatus.textContent = formatMeetingSupportStatus(state.supportStatus);
  meetingFallbackStatus.textContent = state.fallbackMessage ?? "None";
  meetingActive.textContent = state.activeSessionId ? `Yes • ${state.activeSessionId}` : "No";

  meetingGuidance.innerHTML = "";
  const selectedOption = state.options.find((option) => option.surface === state.selectedSurface) ?? state.options[0];
  if (selectedOption) {
    const heading = document.createElement("li");
    heading.textContent = selectedOption.description;
    meetingGuidance.appendChild(heading);

    for (const item of selectedOption.fallbackGuidance) {
      const li = document.createElement("li");
      li.textContent = item;
      meetingGuidance.appendChild(li);
    }
  }

  if (state.fallbackMessage) {
    const li = document.createElement("li");
    li.textContent = state.fallbackMessage;
    meetingGuidance.appendChild(li);
  }
}

function renderExperimentalGoogleMeet(state: ExperimentalGoogleMeetState) {
  experimentalGoogleMeetFlag.textContent = state.featureFlag;
  experimentalGoogleMeetStatus.textContent = formatExperimentalGoogleMeetStatus(state.status);
  experimentalGoogleMeetAvailability.textContent = state.available ? "Available in lab mode" : "Unavailable";
  experimentalGoogleMeetActive.textContent = state.activeSessionId ? `Yes • ${state.activeSessionId}` : "No";
  experimentalGoogleMeetEnabled.checked = state.enabled;
  experimentalGoogleMeetEnabled.disabled = !state.available;
  saveExperimentalGoogleMeetButtonEl.disabled = !state.available;
  refreshExperimentalGoogleMeetButtonEl.disabled = false;

  experimentalGoogleMeetNotesList.innerHTML = "";
  for (const note of state.notes) {
    const item = document.createElement("li");
    item.textContent = note;
    experimentalGoogleMeetNotesList.appendChild(item);
  }

  if (!state.available) {
    experimentalGoogleMeetErrorLabel.textContent = "Lab mode is blocked until the companion starts with VOICE_TO_TEXT_EXPERIMENTAL_GOOGLE_MEET=1.";
    return;
  }

  experimentalGoogleMeetErrorLabel.textContent = state.enabled
    ? "The prototype boundary is enabled, but it still does not join Google Meet as a bot."
    : "The prototype boundary is disabled. Enable it only for lab testing.";
}

function renderNotesState(message: string, notes: LiveNotesResponse["notes"]) {
  notesStatus.textContent = message;
  notesListEl.innerHTML = "";

  if (notes.notes.length === 0) {
    const emptyItem = document.createElement("li");
    emptyItem.className = "transcript-empty";
    emptyItem.textContent = "No notes yet.";
    notesListEl.appendChild(emptyItem);
    return;
  }

  const existingLatest = notesListEl.querySelector(".transcript-item--latest");
  existingLatest?.classList.remove("transcript-item--latest");

  notes.notes.forEach((note, index) => {
    const item = document.createElement("li");
    item.className = "transcript-item";
    item.innerHTML = `
      <div class="transcript-meta">
        <strong>Live note</strong>
        <span>${new Date(note.createdAt).toLocaleTimeString()}</span>
      </div>
      <p>${note.text}</p>
    `;
    if (index === notes.notes.length - 1) {
      item.classList.add("transcript-item--latest");
    }
    notesListEl.appendChild(item);
  });

  const latestItem = notesListEl.querySelector(".transcript-item--latest");
  latestItem?.scrollIntoView({ block: "nearest", behavior: "smooth" });
}

function renderSummaryState(message: string, summary: FinalSummary | null) {
  summaryStatus.textContent = message;

  if (!summary) {
    summaryOverview.textContent = "No summary yet.";
    summaryPoints.innerHTML = "<li>Stop the session to generate a summary.</li>";
    return;
  }

  summaryOverview.textContent = summary.overview;
  summaryPoints.innerHTML = "";
  summary.keyPoints.forEach((point) => {
    const item = document.createElement("li");
    item.textContent = point;
    summaryPoints.appendChild(item);
  });
}

function renderArchiveDetail(entry: SessionArchiveEntry | null) {
  if (!entry) {
    historyStatus.textContent = "None selected";
    historyDetailEl.innerHTML = "<p>Select a completed session to inspect its transcript, notes, and summary.</p>";
    return;
  }

  historyStatus.textContent = entry.session.id;
  const summary = entry.summary.summary;
  historyDetailEl.innerHTML = `
    <div class="history-detail-stack">
      <div class="history-detail-header">
        <div>
          <p class="history-eyebrow">Completed session</p>
          <h3>${entry.session.sourceType} • ${entry.session.runtimeId}</h3>
        </div>
        <span class="history-badge">${entry.session.status}</span>
      </div>
      <div class="history-detail-grid">
        <div><strong>Started</strong><span>${new Date(entry.session.startedAt).toLocaleString()}</span></div>
        <div><strong>Completed</strong><span>${entry.session.endedAt ? new Date(entry.session.endedAt).toLocaleString() : "Unknown"}</span></div>
        <div><strong>Transcript chunks</strong><span>${entry.transcript.segmentCount}</span></div>
        <div><strong>Live notes</strong><span>${entry.notes.noteCount}</span></div>
        ${
          entry.session.sourceType === "meeting-helper"
            ? `
        <div><strong>Meeting route</strong><span>${formatMeetingSurface(entry.session.meetingSurface ?? entry.session.meetingRequestedSurface ?? "desktop-meeting")}</span></div>
        <div><strong>Meeting support</strong><span>${entry.session.meetingSupportStatus ? formatMeetingSupportStatus(entry.session.meetingSupportStatus) : "Unknown"}</span></div>
        ${
          entry.session.meetingRequestedSurface && entry.session.meetingRequestedSurface !== entry.session.meetingSurface
            ? `<div><strong>Fallback</strong><span>${formatMeetingSurface(entry.session.meetingRequestedSurface)} fell back to ${formatMeetingSurface(entry.session.meetingSurface ?? "browser-meeting")}</span></div>`
            : ""
        }
            `
            : ""
        }
      </div>
      <div class="history-summary">
        <h4>Summary</h4>
        <p>${summary?.overview ?? "No summary stored."}</p>
        <ul>
          ${(summary?.keyPoints ?? []).map((point) => `<li>${point}</li>`).join("") || "<li>No summary points stored.</li>"}
        </ul>
      </div>
      <div class="history-excerpt">
        <h4>Latest note</h4>
        <p>${entry.notes.notes.at(-1)?.text ?? "No live notes captured."}</p>
      </div>
    </div>
  `;
}

function renderArchiveList(entries: SessionArchiveEntry[]) {
  historyCount.textContent = String(entries.length);
  historyListEl.innerHTML = "";

  if (entries.length === 0) {
    const emptyItem = document.createElement("li");
    emptyItem.className = "transcript-empty";
    emptyItem.textContent = "No archived sessions yet.";
    historyListEl.appendChild(emptyItem);
    renderArchiveDetail(null);
    return;
  }

  for (const entry of entries) {
    const item = document.createElement("li");
    item.className = "history-item";
    if (entry.session.id === selectedArchiveSessionId) {
      item.classList.add("history-item--selected");
    }
    item.innerHTML = `
      <button type="button" class="history-button">
        <strong>${entry.session.sourceType}</strong>
        <span>${new Date(entry.session.startedAt).toLocaleString()}</span>
        <small>
          ${entry.transcript.segmentCount} transcript chunks • ${entry.notes.noteCount} notes${entry.session.sourceType === "meeting-helper" ? ` • ${formatMeetingSurface(entry.session.meetingSurface ?? entry.session.meetingRequestedSurface ?? "desktop-meeting")}` : ""}
        </small>
      </button>
    `;
    const button = item.querySelector("button");
    button?.addEventListener("click", () => {
      selectedArchiveSessionId = entry.session.id;
      void refreshArchiveSelection(entry.session.id);
      renderArchiveList(archivedSessions);
    });
    historyListEl.appendChild(item);
  }
}

async function requestJson<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${companionBaseUrl}${path}`, {
    headers: {
      "content-type": "application/json"
    },
    ...init
  });

  const data = (await response.json()) as T | SessionError;

  if (!response.ok) {
    throw new Error((data as SessionError).message ?? "Request failed");
  }

  return data as T;
}

async function refreshSession() {
  try {
    const payload = await requestJson<SessionStatusResponse>("/session");
    renderSession(payload.session);
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Companion unavailable");
  }
}

async function refreshRuntimeConfig() {
  try {
    const payload = await requestJson<RuntimeConfigResponse>("/config");
    renderRuntimeConfig(payload.config);
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to load runtime config");
  }
}

async function refreshMeetingHelper() {
  try {
    const payload = await requestJson<MeetingHelperResponse>("/meeting-helper");
    renderMeetingHelper(payload.meetingHelper);
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to load meeting helper");
  }
}

async function refreshExperimentalGoogleMeet() {
  try {
    const payload = await requestJson<ExperimentalGoogleMeetResponse>("/experimental/google-meet");
    renderExperimentalGoogleMeet(payload.experimentalGoogleMeet);
  } catch (error) {
    experimentalGoogleMeetErrorLabel.textContent = error instanceof Error ? error.message : "Unable to load experimental Google Meet state";
  }
}

async function saveMeetingHelperSelection(surface = selectedMeetingSurface) {
  const payload: UpdateMeetingHelperRequest = { surface };

  try {
    const response = await requestJson<UpdateMeetingHelperResponse>("/meeting-helper", {
      method: "POST",
      body: JSON.stringify(payload)
    });
    renderMeetingHelper(response.meetingHelper);
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to save meeting helper");
  }
}

async function saveExperimentalGoogleMeetSelection(enabled = experimentalGoogleMeetEnabled.checked) {
  const payload: UpdateExperimentalGoogleMeetRequest = { enabled };

  try {
    const response = await requestJson<UpdateExperimentalGoogleMeetResponse>("/experimental/google-meet", {
      method: "POST",
      body: JSON.stringify(payload)
    });
    renderExperimentalGoogleMeet(response.experimentalGoogleMeet);
    void refreshMeetingHelper();
  } catch (error) {
    experimentalGoogleMeetErrorLabel.textContent = error instanceof Error ? error.message : "Unable to save experimental Google Meet state";
  }
}

async function refreshTranscript() {
  try {
    const payload = await requestJson<TranscriptResponse>(`/transcript?sinceSegmentCount=${transcriptSegments.length}`);
    if (payload.transcript.revision !== transcriptRevision) {
      const incomingSegments = payload.transcript.segments;
      if (incomingSegments.length > 0) {
        transcriptSegments = [...transcriptSegments, ...incomingSegments];
      }
      transcriptRevision = payload.transcript.revision;
      updateTranscriptMetrics(payload.transcript);
      renderTranscriptState(
        `${payload.transcript.isActive ? "Simulated streaming transcript" : "Transcript paused"}${payload.transcript.isSimulated ? " (simulated)" : ""} • revision ${payload.transcript.revision}`,
        incomingSegments,
        incomingSegments.length > 0
      );
    } else {
      updateTranscriptMetrics(payload.transcript);
      if (currentSession?.status === "recording") {
        transcriptStatus.textContent = `Polling transcript stream... revision ${transcriptRevision}`;
      }
    }
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to load transcript stream");
  }
}

async function refreshLiveNotes() {
  try {
    const payload = await requestJson<LiveNotesResponse>("/notes");
    if (payload.notes.revision !== notesRevision) {
      notesRevision = payload.notes.revision;
      updateNotesMetrics(payload.notes);
      renderNotesState(
        `${payload.notes.isActive ? "Simulated live notes" : "Notes paused"}${payload.notes.isSimulated ? " (simulated)" : ""} • revision ${payload.notes.revision}`,
        payload.notes
      );
      return;
    }

    updateNotesMetrics(payload.notes);
    if (currentSession?.status === "recording") {
      notesStatus.textContent = `Polling live notes... revision ${notesRevision}`;
    }
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to load live notes");
  }
}

async function refreshSummary() {
  try {
    const payload = await requestJson<SummaryResponse>("/summary");
    if (payload.summary.isReady && payload.summary.summary) {
      currentSummary = payload.summary.summary;
      renderSummaryState(
        `${payload.summary.isSimulated ? "Simulated summary" : "Final summary"} ready • revision ${payload.summary.revision}`,
        payload.summary.summary
      );
      return;
    }

    currentSummary = null;
    renderSummaryState("Waiting for session to complete", null);
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to load summary");
  }
}

async function refreshArchive() {
  try {
    const payload = await requestJson<SessionArchiveListResponse>("/sessions");
    archivedSessions = [...payload.sessions];

    if (!selectedArchiveSessionId && archivedSessions.length > 0) {
      selectedArchiveSessionId = archivedSessions[0].session.id;
    }

    renderArchiveList(archivedSessions);

    if (selectedArchiveSessionId) {
      await refreshArchiveSelection(selectedArchiveSessionId);
    }
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to load session archive");
  }
}

async function refreshArchiveSelection(sessionId: string) {
  try {
    const payload = await requestJson<SessionArchiveResponse>(`/sessions/${encodeURIComponent(sessionId)}`);
    renderArchiveDetail(payload.session);
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to load archived session");
  }
}

function stopTranscriptPolling() {
  if (transcriptTimerId !== null) {
    window.clearInterval(transcriptTimerId);
    transcriptTimerId = null;
  }
}

function stopNotesPolling() {
  if (notesTimerId !== null) {
    window.clearInterval(notesTimerId);
    notesTimerId = null;
  }
}

function startTranscriptPolling() {
  stopTranscriptPolling();
  transcriptTimerId = window.setInterval(() => {
    if (currentSession?.status === "recording") {
      void refreshTranscript();
      return;
    }

    stopTranscriptPolling();
  }, 1500);
}

function startNotesPolling() {
  stopNotesPolling();
  notesTimerId = window.setInterval(() => {
    if (currentSession?.status === "recording") {
      void refreshLiveNotes();
      return;
    }

    stopNotesPolling();
  }, 1700);
}

sessionForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  const payload: StartSessionRequest = {
    sourceType: selectedMode,
    runtimeId: selectedRuntimeId as StartSessionRequest["runtimeId"],
    language: defaultLanguage,
    saveTranscript: saveTranscriptEl.checked,
    saveSummary: saveSummaryEl.checked,
    meetingSurface: selectedMode === "meeting-helper" ? selectedMeetingSurface : undefined
  };

  try {
    const response = await requestJson<SessionStartResponse>("/session/start", {
      method: "POST",
      body: JSON.stringify(payload)
    });
    renderSession(response.session);
    transcriptRevision = 0;
    transcriptSegments = [];
    notesRevision = 0;
    currentSummary = null;
    transcriptChunkCount.textContent = "0";
    transcriptRevisionDisplay.textContent = "0";
    transcriptUpdated.textContent = "Never";
    transcriptListEl.innerHTML = "";
    notesCount.textContent = "0";
    notesRevisionDisplay.textContent = "0";
    notesUpdated.textContent = "Never";
    notesListEl.innerHTML = "";
    renderNotesState("Simulated live notes (waiting for chunks)", {
      sessionId: null,
      revision: 0,
      updatedAt: null,
      noteCount: 0,
      isSimulated: true,
      isActive: false,
      notes: []
    });
    renderSummaryState("Waiting for session to complete", null);
    renderTranscriptState("Simulated streaming transcript (waiting for chunks)", transcriptSegments);
    void refreshMeetingHelper();
    void refreshExperimentalGoogleMeet();
    startTranscriptPolling();
    startNotesPolling();
    void refreshTranscript();
    void refreshLiveNotes();
    void refreshSummary();
    void refreshArchive();
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to start session");
  }
});

stopButton.addEventListener("click", async () => {
  if (!currentSession) {
    renderError("No active session to stop.");
    return;
  }

  const payload: StopSessionRequest = {
    sessionId: currentSession.id
  };

  try {
    const response = await requestJson<SessionStopResponse>("/session/stop", {
      method: "POST",
      body: JSON.stringify(payload)
    });
    renderSession(response.session);
    selectedArchiveSessionId = response.session.id;
    stopTranscriptPolling();
    stopNotesPolling();
    void refreshMeetingHelper();
    void refreshExperimentalGoogleMeet();
    void refreshTranscript();
    void refreshLiveNotes();
    void refreshSummary();
    void refreshArchive();
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to stop session");
  }
});

captureModeInput.addEventListener("change", () => {
  selectedMode = captureModeInput.value as CaptureMode;
  selectedModeDisplay.textContent = selectedMode;
});

runtimeSelectEl.addEventListener("change", () => {
  selectedRuntimeId = runtimeSelectEl.value as RuntimeId;
  selectedRuntimeDisplay.textContent = selectedRuntimeId || "unknown";
});

meetingSurface.addEventListener("change", () => {
  selectedMeetingSurface = meetingSurface.value as MeetingSurface;
  void saveMeetingHelperSelection(selectedMeetingSurface);
});

applyMeetingHelper.addEventListener("click", () => {
  void saveMeetingHelperSelection(selectedMeetingSurface);
});

meetingFallback.addEventListener("click", () => {
  selectedMeetingSurface = "browser-meeting";
  meetingSurface.value = selectedMeetingSurface;
  void saveMeetingHelperSelection(selectedMeetingSurface);
});

saveExperimentalGoogleMeetButtonEl.addEventListener("click", () => {
  void saveExperimentalGoogleMeetSelection(experimentalGoogleMeetEnabled.checked);
});

refreshExperimentalGoogleMeetButtonEl.addEventListener("click", () => {
  void refreshExperimentalGoogleMeet();
});

saveRuntimeEl.addEventListener("click", async () => {
  const payload: UpdateRuntimeConfigRequest = {
    runtimeId: selectedRuntimeId as UpdateRuntimeConfigRequest["runtimeId"],
    language: DEFAULT_LANGUAGE,
    saveTranscript: saveTranscriptEl.checked,
    saveSummary: saveSummaryEl.checked
  };

  try {
    const response = await requestJson<UpdateRuntimeConfigResponse>("/config", {
      method: "POST",
      body: JSON.stringify(payload)
    });
    renderRuntimeConfig(response.config);
  } catch (error) {
    renderError(error instanceof Error ? error.message : "Unable to save runtime config");
  }
});

selectedMode = captureModeInput.value as CaptureMode;
startButton.disabled = false;
runtimeSelectEl.disabled = true;
saveRuntimeEl.disabled = true;
syncElapsedTime(null);
void refreshRuntimeConfig();
void refreshMeetingHelper();
void refreshExperimentalGoogleMeet();
void refreshSession();
void refreshTranscript();
void refreshLiveNotes();
void refreshSummary();
void refreshArchive();
startTranscriptPolling();
startNotesPolling();
