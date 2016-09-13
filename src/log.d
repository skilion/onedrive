import std.stdio;

// enable verbose logging
bool verbose;

void log(T...)(T args)
{
	// Logging to stdout rather than stderr
	stdout.writeln(args);
}

void vlog(T...)(T args)
{
	// Logging to stdout rather than stderr
	if (verbose) stdout.writeln(args);
}
