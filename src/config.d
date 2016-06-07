import std.file, std.regex, std.stdio, std.array;

struct Config
{
	private string[string] values;

	this(string[] filenames...)
	{
		bool found = false;
		foreach (filename; filenames) {
			if (exists(filename)) {
				found = true;
				load(filename);
			}
		}
		if (!found) {
                        if (filenames && filenames[0] != "empty") { // not a unit test
                            writeln("Configuration file is not found.");
                            writeln();
                            writeln("If this is the first time you run onedrive, you should create a configuration");
                            writeln("file in ", join(filenames.reverse, " or "), ". Run:");
                            writeln();
                            writeln("mkdir -p ~/.config/onedrive");
                            writeln("cat > ~/.config/onedrive/config << EOF");
                            writeln("client_id = \"\"");
                            writeln("client_secret = \"\"");
                            writeln("sync_dir = \"~/OneDrive\"");
                            writeln("skip_file = \".*|~*\"");
                            writeln("skip_dir = \".*\"");
                            writeln("EOF");
                            writeln();
                            writeln("Then edit ~/.config/onedrive/config.");
                            writeln("To get client_id and client_secret, please register this application at");
                            writeln("https://dev.onedrive.com/app-registration.htm");
                            writeln("and copy both keys from App Settings.");
                            writeln();
                        }
                        throw new Exception("No config file found");
                }
	}

	string get(string key)
	{
		auto p = key in values;
		if (p) {
			return *p;
		} else {
			throw new Exception("Missing config value: " ~ key);
		}
	}

	private void load(string filename)
	{
		auto file = File(filename, "r");
		auto r = regex(`^\s*(\w+)\s*=\s*"(.*)"\s*$`);
		foreach (line; file.byLine()) {
			auto c = line.matchFirst(r);
			if (!c.empty) {
				c.popFront(); // skip the whole match
				string key = c.front.dup;
				c.popFront();
				values[key] = c.front.dup;
			} else {
				writeln("Malformed config line: ", line);
			}
		}
	}
}

unittest
{
	auto cfg = Config("empty", "onedrive.conf");
	assert(cfg.get("sync_dir") == "~/OneDrive");
}

unittest
{
	try {
		auto cfg = Config("empty");
		assert(0);
	} catch (Exception e) {
	}
}
