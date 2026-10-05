/// veida "an isometric coffee shop, pastel palette"
import std.array : join;
import std.stdio;
import veida;

int main(string[] args)
{
    auto prompt = args[1 .. $].join(" ");
    if (!prompt.length) { stderr.writeln(`usage: veida "your prompt"`); return 2; }
    auto r = generate(prompt);
    if (!r.ok) { stderr.writeln(r.reason, ": ", r.message); return r.reason == Reason.quota ? 3 : 1; }
    writeln(r.image.url);
    return 0;
}
