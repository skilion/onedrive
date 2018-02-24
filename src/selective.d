import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.stdio;
import util;

final class SelectiveSync
{
	private string[] paths;
	private Regex!char mask;

	void load(string filepath)
	{
		if (exists(filepath)) {
			paths = File(filepath)
				.byLine()
				.map!(a => buildNormalizedPath(a))
				.filter!(a => a.length > 0)
				.array;
		}
	}

	void setMask(const(char)[] mask)
	{
		this.mask = wild2regex(mask);
	}

	bool isNameExcluded(string name)
	{
		return !name.matchFirst(mask).empty;
	}

	bool isPathExcluded(string path)
	{
		return .isPathExcluded(path, paths);
	}
}

// Test if the given path is included or excluded from syncronization.
//
// Iterate through the list of inclusion/exclusion paths in
// pathList. If the test path is a prefix of or equal to the given
// path, apply the respective action:
//
// A test path starting with '-' means exclude
// A path starting with '+' means include
// A path starting with any other character means include.
//
// A '+' or '-' as the first character is stripped of before
// comparision.
//
private bool isPathExcluded(string path, string[] pathList)
{
	// always include the root
	if (path == ".") return false;
	// if there are no paths to check always include
	if (pathList.empty) return false;

	path = buildNormalizedPath(path);
	bool exclude;
	int offset;
	foreach (testPath; pathList) {
		switch (testPath[0]) {
		case '-':
			exclude = true;
			offset = 1;
			break;
		case '+':
			offset = 1;
			exclude = false;
			break;
		default:
			offset = 0;
			exclude = false;
		}
		auto comm = commonPrefix(path, testPath[offset..$]);
		if (comm.length == testPath[offset..$].length) {
			// path is contained in testPath:
			// in/exclude according to type of testPath
			return exclude;
		}
	}
	// exclude any unmatched path
	return true;
}

unittest
{
	assert(isPathExcluded("Documents2", ["Documents"]));
	assert(!isPathExcluded("Documents", ["Documents"]));
	assert(!isPathExcluded("Documents/a.txt", ["Documents"]));
	assert(isPathExcluded("Hello/World", ["Hello/John"]));
	assert(!isPathExcluded(".", ["Documents"]));
	assert(!isPathExcluded("any",["+."]));
	assert(isPathExcluded("nothing",["-."]));
	assert(!isPathExcluded("some/path", ["+some/path", "-."]));
	assert(!isPathExcluded("some/path/below", ["some", "-some/path"]));
}
