// Listener tests: transcripts as speech recognition delivers them (partial results that grow and get rewritten),
// fed straight to the listener with the microphone off. The tricky cases come from real use. Run with tests/run.sh.

import AVFoundation
import Foundation

var failures = 0
func expect(_ name: String, _ ok: Bool, _ detail: String) {
    if !ok { failures += 1 }
    print(ok ? "ok  " : "FAIL", name, "→", detail)
}

func listener(_ phrase: String = "Hey Otto") -> Listener {
    let l = Listener()
    l.micEnabled = false
    l.wakePhrase = phrase
    l.wakeEnabled = true
    return l
}

/// Feeds partial transcripts; returns whether it woke, the request heard, and whether it was interrupted.
func run(_ l: Listener, _ partials: [String]) -> (woke: Bool, request: String, interrupted: Bool) {
    var woke = false, request = "", interrupted = false
    l.onWake = { woke = true }
    l.onPartial = { request = $0 }
    l.onBargeIn = { interrupted = true }
    partials.forEach(l.heard)
    return (woke, request, interrupted)
}

// MARK: Wake phrase, including recognition rewriting or dropping it

var r = run(listener(), ["Hey Otto", "Hey Otto what's", "Hey order what's the weather", "Hey order what's the weather today"])
expect("wake phrase rewritten", r.woke && r.request == "what's the weather today", "“\(r.request)”")
r = run(listener(), ["Hey Otto Ca", "Can you tell me what the traffic will be like around 6 PM"])
expect("wake phrase dropped", r.request == "Can you tell me what the traffic will be like around 6 PM", "“\(r.request)”")
r = run(listener(), ["Hey Otto", "How are you doing"])
expect("wake phrase dropped before any request", r.request == "How are you doing", "“\(r.request)”")
r = run(listener(), ["Hey, Otto, open", "Hey, Otto, open Spotify"])
expect("punctuation", r.request == "open Spotify", "“\(r.request)”")
r = run(listener(), ["Hey Otto open mail and hey Otto close it"])
expect("said twice: the last one counts", r.request == "close it", "“\(r.request)”")
r = run(listener(), ["Hey auto what's the time"])
expect("“Hey auto” is Otto", r.woke && r.request == "what's the time", "“\(r.request)”")
r = run(listener("Hey Claude"), ["Hey Claude", "Hey cloud what time", "A clothes what time is it"])
expect("custom phrase with mishearings", r.request == "what time is it", "“\(r.request)”")
r = run(listener(), ["I bought a new auto yesterday"])
expect("the name alone doesn't wake", !r.woke, "woke=\(r.woke)")

// MARK: Recognition restarting in the middle of a request

let restarted = listener()
r = run(restarted, ["Hey Otto can you check my"])
restarted.taskEnded()
restarted.heard("other pull requests")
expect("restart mid-request keeps the words", restarted.capturing && r.request == "can you check my", "still capturing=\(restarted.capturing)")

// MARK: Talking over the spoken answer

func speaking(_ answer: String, _ partials: [String], echoCancelling: Bool) -> (request: String, interrupted: Bool) {
    let l = listener()
    l.echoCancelling = echoCancelling
    var request = "", interrupted = false
    l.onPartial = { request = $0 }
    l.onBargeIn = { interrupted = true }
    l.listenDuringSpeech(answer)
    partials.forEach(l.heard)
    return (request, interrupted)
}
let meeting = "Your next meeting is with Sofia about the quarterly report, and after that you're free until five. The office on Tchoupitoulas Street says the parking lot is closed today."
let traffic = "I didn't find any closures or events reported downtown today, so expect a normal evening commute."
let events = "I couldn't find anything big downtown today, like protests, games or road closures."
let pr = "Your open pull request is the payments one for safe money rounding, number 214. Its tests pass, but the linter is failing."

// Its own voice as the microphone heard it from laptop speakers before echo cancellation: words come back misheard
// ("or" → "our", "reported" → "report", "Sofia" → "Sophie", "protests" cut to "pro"). With echo cancellation little gets
// through, but what does must still not count as the user.
for ec in [false, true] {
    let mode = ec ? "[echo cancelled]" : "[no echo cancelling]"
    var s = speaking(traffic, ["I didn't find any closures our events report", "I didn't find any closures our events reported downtown"], echoCancelling: ec)
    expect("echo: “our events report” \(mode)", !s.interrupted, "interrupted=\(s.interrupted)")
    s = speaking(meeting, ["Your next meeting is with Sophie about the quarterly rep", "Your next meeting is with Sophie about the quarterly report and after"], echoCancelling: ec)
    expect("echo: “Sophie … quarterly rep” \(mode)", !s.interrupted, "interrupted=\(s.interrupted)")
    s = speaking(events, ["I couldn't find anything big downtown today like pro", "I couldn't find anything big downtown today like protests"], echoCancelling: ec)
    expect("echo: “like pro” \(mode)", !s.interrupted, "interrupted=\(s.interrupted)")
    s = speaking(pr, ["Your open pull request is the court payment one for the small safe money"], echoCancelling: ec)
    expect("echo: misheard words \(mode)", !s.interrupted, "interrupted=\(s.interrupted)")
    s = speaking(pr, ["Your open pull request is stop"], echoCancelling: ec)
    expect("say stop \(mode)", s.interrupted && s.request == "stop", "interrupted=\(s.interrupted) “\(s.request)”")
    s = speaking(pr, ["Your open pull request is wait"], echoCancelling: ec)
    expect("say wait \(mode)", s.interrupted && s.request == "wait", "interrupted=\(s.interrupted) “\(s.request)”")
    s = speaking(pr, ["Your open pull Hey Otto what's the time"], echoCancelling: ec)
    expect("wake phrase over it \(mode)", s.request == "what's the time", "“\(s.request)”")
    s = speaking(traffic, ["I didn't find any closures or events okay thanks what about tomorrow morning"], echoCancelling: ec)
    expect("follow-up over it \(mode)", s.interrupted && s.request.hasPrefix("okay thanks what about"), "interrupted=\(s.interrupted) “\(s.request)”")
}
// Without echo cancelling, garbled names come through two or three words at a time; it must take more to interrupt.
var s = speaking(meeting, ["Your next meeting is with Sofia about the quarterly report and after that you're free until five the office on chop it to less street says the parking lot"], echoCancelling: false)
expect("echo: mangled street name [no echo cancelling]", !s.interrupted, "interrupted=\(s.interrupted)")
// With echo cancellation, a couple of words is enough.
s = speaking(pr, ["Your open pull request is no actually", "Your open pull request is no actually open my calendar please"], echoCancelling: true)
expect("talk over it [echo cancelled]", s.interrupted && s.request.hasPrefix("actually open my calendar"), "interrupted=\(s.interrupted) “\(s.request)”")
s = speaking(events, ["I couldn't find anything big downtown today what about the weekend"], echoCancelling: true)
expect("short question over it [echo cancelled]", s.interrupted && s.request.hasPrefix("what about the weekend"), "interrupted=\(s.interrupted) “\(s.request)”")

// MARK: Speaking

var text = "Your next event is at 3 pm. Then you're free! The rest is"
var sentences = Speaker.sentences(from: &text)
expect("sentences: whole ones are taken, the rest waits", sentences == ["Your next event is at 3 pm.", "Then you're free!"] && text == "The rest is", "\(sentences) + “\(text)”")
text = "It costs $3.50 today. "
sentences = Speaker.sentences(from: &text)
expect("sentences: decimals don't split", sentences == ["It costs $3.50 today."], "\(sentences)")
text = "Here's **the** [link](https://example.com) to it.\nNext line"
sentences = Speaker.sentences(from: &text)
expect("sentences: markdown cleaned, newline ends a sentence", sentences == ["Here's the link to it."] && text == "Next line", "\(sentences) + “\(text)”")

text = "Your next meeting is at three with the design team, and after that you're free"
sentences = Speaker.sentences(from: &text, first: true)
expect("first clause goes early", sentences == ["Your next meeting is at three with the design team,"] && text == "and after that you're free", "\(sentences) + “\(text)”")
text = "Sure, one moment"
sentences = Speaker.sentences(from: &text, first: true)
expect("short opening isn't split", sentences.isEmpty, "\(sentences)")

// MARK: Turn-taking

let timing = listener()
timing.pauseToEnd = 1.8
expect("finished sentence sends quickly", timing.pauseNeeded(for: "What's on my calendar tomorrow?") < 1.0, "\(timing.pauseNeeded(for: "What's on my calendar tomorrow?")) s")
expect("trailing word waits longer", timing.pauseNeeded(for: "Can you check my.") > 2.5, "\(timing.pauseNeeded(for: "Can you check my."))")
expect("no punctuation: normal pause", timing.pauseNeeded(for: "open the latest report from finance") == 1.8, "\(timing.pauseNeeded(for: "open the latest report from finance"))")
expect("a word or two waits longer", timing.pauseNeeded(for: "Spotify.") > 2.5, "\(timing.pauseNeeded(for: "Spotify."))")

// MARK: Voice layer tags

func filtered(_ chunks: [String]) -> (speech: String, directives: [Directive]) {
    var f = DirectiveFilter(), speech = "", found: [Directive] = []
    for c in chunks { let r = f.feed(c); speech += r.speech; found += r.directives }
    let r = f.finish(); speech += r.speech; found += r.directives
    return (speech, found)
}
var d = filtered(["Sure, checking your cal", "endar now. <ta", "sk title=\"Calendar\">Check tomorrow's ", "calendar for clashes.</task>"])
expect("tag split across chunks", d.speech == "Sure, checking your calendar now. " && d.directives == [.start(title: "Calendar", instruction: "Check tomorrow's calendar for clashes.")], "“\(d.speech)” \(d.directives)")
d = filtered(["On it, both at once. <task title=\"Report\">Write the report.</task><task title=\"PR\">Review PR 21.</task>"])
expect("two tasks in one reply", d.directives.count == 2 && d.speech == "On it, both at once. ", "\(d.directives)")
d = filtered(["Okay, I'll add tomorrow too.", " <steer id=\"2\">Also check tomorrow.</steer> And stopping the other one. <cancel id=\"3\"/>"])
expect("steer and cancel", d.directives == [.steer(id: 2, text: "Also check tomorrow."), .cancel(id: 3)] && !d.speech.contains("<"), "“\(d.speech)” \(d.directives)")
d = filtered(["Three is < five, and 2 <", " 4 too."])
expect("an ordinary < is spoken", d.speech == "Three is < five, and 2 < 4 too." && d.directives.isEmpty, "“\(d.speech)”")
d = filtered(["Working on it. <task title=\"Cut off\">This never clo"])
expect("unfinished tag is never spoken", d.speech == "Working on it. " && d.directives.isEmpty, "“\(d.speech)”")
d = filtered(["<task>Find the cheapest flight to Lisbon next Friday.</task>On it."])
expect("untitled task gets a title", d.speech == "On it." && { if case .start(let t, _) = d.directives.first { return t.hasPrefix("Find the cheapest") }; return false }(), "\(d.directives)")

let board = TaskBoard()
expect("no tasks: no [Tasks] block", board.summary().isEmpty, "“\(board.summary())”")

// MARK: Background tasks: the cap, the queue, saving and restoring

// A stand-in for Claude Code that just keeps running (it echoes what it's sent), so tasks stay "running".
let fakeClaude = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("otto-fake-claude-\(UUID().uuidString)")
try! "#!/bin/sh\nexec cat\n".write(to: fakeClaude, atomically: true, encoding: .utf8)
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)
UserDefaults.standard.register(defaults: ["claudePath": fakeClaude.path])   // in memory only

let tasks = TaskBoard()
tasks.limit = 2
let one = tasks.start(title: "One", instruction: "do one"), two = tasks.start(title: "Two", instruction: "do two")
let three = tasks.start(title: "Three", instruction: "do three")
expect("cap: two run, the third queues", tasks.running.count == 2 && three.status == .queued, "running \(tasks.running.count), #3 \(three.status)")
expect("the voice hears it's queued", tasks.summary().contains("#3 “Three”: queued"), tasks.summary())
tasks.steer(three.id, "also do four")
expect("steering a queued task adds to it", three.next.hasSuffix("Also: also do four") && three.status == .queued, three.next)
tasks.cancel(one.id)
expect("a free slot starts the queued task", three.status == .running && one.status == .cancelled && tasks.running.count == 2, "#3 \(three.status)")
tasks.limit = 3
let four = tasks.start(title: "Four", instruction: "do four")
expect("raising the cap lets more run", four.status == .running && tasks.running.count == 3, "running \(tasks.running.count)")

let saved = tasks.snapshot()
let restored = TaskBoard()
restored.restore(saved, nextID: tasks.nextID)
let back = restored.tasks.first { $0.id == two.id }
expect("restored: running tasks come back interrupted", back?.status == .interrupted && restored.tasks.first { $0.id == one.id }?.status == .cancelled,
       restored.tasks.map { "#\($0.id) \($0.status)" }.joined(separator: ", "))
expect("restored: numbering continues", restored.start(title: "Five", instruction: "do five").id == 5, "next id \(restored.nextID)")
expect("the voice hears it can continue an interrupted task", restored.summary().contains("#2 “Two”: interrupted"), restored.summary())
restored.steer(two.id, "carry on")
expect("steering an interrupted task restarts it", back?.status == .running, "\(back?.status.rawValue ?? "missing")")
tasks.shutdown(); restored.shutdown()
try? FileManager.default.removeItem(at: fakeClaude)

// The format `say` renders must be the one the player is connected with (it would refuse the audio otherwise).
let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("otto-test-\(UUID().uuidString).caf")
let say = Process()
say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
say.arguments = ["--data-format=LEF32@24000", "-o", file.path, "Format check."]
try? say.run(); say.waitUntilExit()
let rendered = try? AVAudioFile(forReading: file)
expect("say renders the player's format", rendered?.processingFormat == Speaker.format, "\(rendered.map { "\($0.processingFormat)" } ?? "no file")")
try? FileManager.default.removeItem(at: file)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
