import streamDeck, { action, KeyDownEvent, KeyUpEvent, SingletonAction, WillAppearEvent, WillDisappearEvent } from "@elgato/streamdeck";
import net from "node:net";

// Der Plugin-Prozess spricht nur mit dem lokalen Funk-App.
// Warum? Das Mikrofon gehört der Funk-App (eigene Mikrofonfreigabe),
// das Plugin ist nur die "Sprechtaste" und die Anzeige.
const HELPER_PORT = 47811;

type Status = { helper: boolean; peers: number; sending: boolean; receiving: boolean; muted: boolean; partnerMuted: boolean };
const OFFLINE: Status = { helper: false, peers: 0, sending: false, receiving: false, muted: false, partnerMuted: false };
let status: Status = { ...OFFLINE };

let socket: net.Socket | null = null;
let rxBuf = "";
const pressed = new Set<string>(); // Kontexte, deren Taste gerade gehalten wird

function send(obj: object) {
	if (socket && !socket.destroyed) socket.write(JSON.stringify(obj) + "\n");
}

function syncTalk() {
	send({ cmd: "talk", on: pressed.size > 0 });
}

function connect() {
	const s = net.createConnection({ host: "127.0.0.1", port: HELPER_PORT });
	s.setNoDelay(true);
	s.on("connect", () => {
		socket = s;
		status.helper = true;
		syncTalk();
		render();
	});
	s.on("data", (d) => {
		rxBuf += d.toString("utf8");
		let i: number;
		while ((i = rxBuf.indexOf("\n")) >= 0) {
			const line = rxBuf.slice(0, i);
			rxBuf = rxBuf.slice(i + 1);
			try {
				const msg = JSON.parse(line);
				if (msg.status) {
					status = { ...OFFLINE, ...msg.status, helper: true };
					render();
				}
			} catch {
				/* kaputte Zeile ignorieren */
			}
		}
	});
	const lost = () => {
		if (socket === s) socket = null;
		rxBuf = "";
		if (status.helper) {
			status = { ...OFFLINE };
			render();
		}
	};
	s.on("error", () => {});
	s.on("close", () => {
		lost();
		setTimeout(connect, 2000); // App neu gestartet? Einfach wieder verbinden.
	});
}

// Tastenbild als SVG, damit wir keine PNG-Sätze pro Zustand pflegen müssen.
function key(bg: string, line1: string, line2: string, ring = false): string {
	const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">
<rect width="144" height="144" rx="18" fill="${bg}"/>
${ring ? '<rect x="6" y="6" width="132" height="132" rx="14" fill="none" stroke="#fff" stroke-width="6"/>' : ""}
<g fill="none" stroke="#fff" stroke-width="7" stroke-linecap="round">
<path d="M52 44 a28 28 0 0 1 40 0"/><path d="M62 56 a14 14 0 0 1 20 0"/></g>
<circle cx="72" cy="68" r="6" fill="#fff"/>
<text x="72" y="106" font-family="Helvetica, Arial, sans-serif" font-size="22" font-weight="700" fill="#fff" text-anchor="middle">${line1}</text>
<text x="72" y="130" font-family="Helvetica, Arial, sans-serif" font-size="16" fill="#fff" fill-opacity="0.85" text-anchor="middle">${line2}</text>
</svg>`;
	return "data:image/svg+xml;charset=utf8," + encodeURIComponent(svg);
}

function currentImage(): string {
	if (!status.helper) return key("#3a3a3a", "FUNK", "App aus");
	if (status.sending && status.receiving) return key("#d9822b", "DUPLEX", "beide reden", true);
	if (status.sending) return key("#c62828", "SENDET", !status.peers ? "niemand da" : status.partnerMuted ? "Partner stumm" : "", true);
	if (status.receiving && status.muted) return key("#5c4b8a", "STUMM", "Partner spricht", true);
	if (status.receiving) return key("#2e7d32", "EMPFANG", "", true);
	if (status.muted) return key("#5c4b8a", "FUNK", "stumm");
	if (status.peers === 0) return key("#3a3a3a", "FUNK", "niemand da");
	return key("#1f3b57", "FUNK", "bereit");
}

let lastImage = "";
function render(force = false) {
	const img = currentImage();
	if (!force && img === lastImage) return;
	lastImage = img;
	for (const a of funk.actions) {
		if (a.isKey()) void a.setImage(img);
	}
}

@action({ UUID: "de.schuchert.funk.talk" })
class FunkAction extends SingletonAction {
	override onWillAppear(_ev: WillAppearEvent) {
		render(true);
	}
	override onWillDisappear(ev: WillDisappearEvent) {
		// Profilwechsel während gehaltener Taste: keyUp käme nie an.
		if (pressed.delete(ev.action.id)) syncTalk();
	}
	override onKeyDown(ev: KeyDownEvent) {
		pressed.add(ev.action.id);
		syncTalk();
		if (!status.helper) void ev.action.showAlert();
	}
	override onKeyUp(ev: KeyUpEvent) {
		pressed.delete(ev.action.id);
		syncTalk();
	}
}

const funk = new FunkAction();
streamDeck.actions.registerAction(funk);
connect();
streamDeck.connect();
