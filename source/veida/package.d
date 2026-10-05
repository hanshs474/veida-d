/**
 * Generate AI images from D with no API key and no account.
 *
 * ---
 * import veida;
 * auto r = generate("matte black ceramic mug on pale oak, soft window light");
 * if (r.ok) writeln(r.image.url); else writeln(r.reason, ": ", r.message);
 * ---
 *
 * Calls the anonymous tier of https://veida.ai, which meters its free allowance
 * against a client id this module invents rather than an account you register:
 * 4 credits per id, 4 per image, 30 per IP per day. Free output is 1K and
 * watermarked. Uses std.net.curl, so libcurl must be present at run time.
 */
module veida;

import core.thread : Thread;
import core.time : seconds;
import std.algorithm : canFind;
import std.datetime.systime : Clock;
import std.format : format;
import std.json;
import std.net.curl : HTTP, get, post;
import std.random : uniform;
import std.string : strip, toLower;
import std.uri : encodeComponent;

/// Why a call failed, in terms of what to do next.
enum Reason { none, quota, rejected, timeout, other }

/// One finished picture.
struct Image { string url; bool watermarked; }

/// The outcome of a call.
struct Result { bool ok; Image image; Reason reason; string message; }

/// Settings for one call. `Options.init` is valid.
struct Options
{
    string aspectRatio = "1:1"; /// "1:1", "16:9", "9:16", "4:3" or "3:4"
    int pollSeconds = 4;
    int timeoutSeconds = 240;
}

/// Service root, changeable for a test or a proxy.
__gshared string baseUrl = "https://veida.ai";

private immutable ratios = ["1:1", "16:9", "9:16", "4:3", "3:4"];

private Result fail(Reason r, string msg) { return Result(false, Image.init, r, "veida: " ~ msg); }

private string anonId()
{
    string s = "d-";
    foreach (_; 0 .. 8) s ~= format("%02x", uniform(0, 256));
    return s;
}

private bool request(string url, string id, string body, out JSONValue data, out Result err)
{
    auto http = HTTP();
    http.addRequestHeader("x-anon-id", id);
    http.addRequestHeader("User-Agent", "veida-d/0.1.0");
    string raw;
    try
    {
        if (body.length)
        {
            http.addRequestHeader("Content-Type", "application/json");
            raw = post(url, body, http).idup;
        }
        else raw = get(url, http).idup;
    }
    catch (Exception e) { err = fail(Reason.other, e.msg); return false; }
    JSONValue env;
    try env = parseJSON(raw);
    catch (Exception) { err = fail(Reason.other, "unexpected response"); return false; }
    auto code = "code" in env;
    if (code is null || code.integer != 0)
    {
        auto m = "message" in env;
        err = fail(Reason.other, (m !is null && m.type == JSONType.string) ? m.str : "request refused");
        return false;
    }
    auto d = "data" in env;
    data = d is null ? parseJSON("{}") : *d;
    return true;
}

private string strField(JSONValue v, string k)
{
    if (v.type != JSONType.object) return "";
    auto p = k in v;
    return (p !is null && p.type == JSONType.string) ? p.str : "";
}

private const(JSONValue)[] arrField(JSONValue v, string k)
{
    if (v.type != JSONType.object) return null;
    auto p = k in v;
    return (p !is null && p.type == JSONType.array) ? p.array : null;
}

/// Interprets the submit response. The quota wall answers 200 with code 0,
/// so it is recognised by a field. On success `r.message` holds the task id.
Result parseSubmit(JSONValue d)
{
    if (d.type == JSONType.object && "wall" in d && d["wall"].type == JSONType.true_)
    {
        if (strField(d, "reason") == "anon_ip_daily")
            return fail(Reason.quota, "this machine has used its 30 free credits for today; sign in at https://veida.ai/pricing");
        return fail(Reason.quota, "free allowance spent; sign in at https://veida.ai/pricing");
    }
    auto task = strField(d, "id");
    if (!task.length) return fail(Reason.other, "the service returned no task id");
    return Result(true, Image.init, Reason.none, task);
}

/// Interprets one poll. Status is not monotonic, so only a terminal failure
/// ends the wait; `r.reason == Reason.none && !r.ok` means keep waiting.
Result parsePoll(JSONValue p)
{
    auto imgs = arrField(p, "images");
    if (imgs.length && imgs[0].type == JSONType.string)
    {
        auto wm = arrField(p, "watermarked");
        return Result(true, Image(imgs[0].str, wm.length && wm[0].type == JSONType.true_));
    }
    auto s = strField(p, "status").toLower;
    if (s == "failed" || s == "error") return fail(Reason.rejected, "prompt refused by the content filter; reword it");
    return Result.init;
}

/// Turns a prompt into an image. Naming the light, the material and the
/// composition moves the result far more than adding adjectives.
Result generate(string prompt, Options o = Options.init)
{
    if (!prompt.strip.length) return fail(Reason.other, "prompt is required");
    if (!ratios.canFind(o.aspectRatio)) return fail(Reason.other, "aspectRatio must be one of 1:1, 16:9, 9:16, 4:3, 3:4");
    auto id = anonId();
    auto deadline = Clock.currTime + (o.timeoutSeconds > 0 ? o.timeoutSeconds : 240).seconds;

    JSONValue payload = parseJSON(`{"provider":"kie","mediaType":"image","model":"veida-image-v1","scene":"text-to-image"}`);
    payload["prompt"] = prompt;
    payload["options"] = parseJSON(`{}`);
    payload["options"]["aspect_ratio"] = o.aspectRatio;

    JSONValue d;
    Result err;
    if (!request(baseUrl ~ "/api/ai/generate", id, payload.toString, d, err)) return err;
    auto sub = parseSubmit(d);
    if (!sub.ok) return sub;
    auto query = baseUrl ~ "/api/ai/anon-query?taskId=" ~ encodeComponent(sub.message) ~ "&provider=kie&mediaType=image";

    while (Clock.currTime < deadline)
    {
        Thread.sleep((o.pollSeconds > 0 ? o.pollSeconds : 4).seconds);
        JSONValue p;
        Result perr;
        if (!request(query, id, "", p, perr)) continue; // a dropped poll is not a failed job
        auto r = parsePoll(p);
        if (r.ok || r.reason != Reason.none) return r;
    }
    return fail(Reason.timeout, "still queued when the deadline passed");
}

unittest
{
    assert(parseSubmit(parseJSON(`{"wall":true,"reason":"anon_ip_daily"}`)).reason == Reason.quota);
    assert(parseSubmit(parseJSON(`{"id":"t1"}`)).message == "t1");
    auto pending = parsePoll(parseJSON(`{"status":"processing"}`));
    assert(!pending.ok && pending.reason == Reason.none);
    assert(parsePoll(parseJSON(`{"status":"failed"}`)).reason == Reason.rejected);
    assert(parsePoll(parseJSON(`{"images":["u"],"watermarked":[true]}`)).image.watermarked);
}
