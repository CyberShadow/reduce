import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.getopt;
import std.parallelism;
import std.path;
import std.process;
import std.stdio;
import std.string;

/// Obviously different compiler versions will compile D programs differently.
/// Thus, we should use a specific version to run the `reduce` test suite against,
/// so we can distinguish changes in results due to `reduce` bugs or unexpected effects of changes,
/// from changes due to differences in how D compiler versions compile D programs.
// Note: when updating this, also update README.md.
enum testSuiteDMDVersion = "v2.080.0";

void main(string[] args)
{
	string[] exclude;
	getopt(args,
		"exclude", &exclude,
	);

	auto tests = args[1..$];
	if (tests.empty)
	{
		tests = dirEntries(".", SpanMode.shallow)
			.filter!(de => de.isDir)
			.map!(de => de.name)
			.filter!(name => !exclude.canFind(name))
			.array;
	}

	{
		auto result = execute(["dmd", "--version"]);
		enforce(result.status == 0, "Can't execute dmd compiler");
		auto dmdVersion = result.output.splitLines[0].split[$-1];
		if (dmdVersion != testSuiteDMDVersion)
			stderr.writefln("WARNING: dmd binary in PATH is version %s, not %s.\n  Test results may be wrong.",
				dmdVersion, testSuiteDMDVersion);
	}

	auto reduce = buildPath("..", "..", "reduce");
	auto flags = ["-g", "-debug", "-unittest", "-cov", "-version=testsuite"];
	version (Windows)
		flags ~= ["-m64"];
	buildPath("..", "cov").rmdirRecurse.collectException;

	stderr.writeln("Building...");
	{
		auto status = spawnProcess(["rdmd", "--build-only", "-of" ~ reduce, "-I../../src"] ~ flags ~ "../../src/reduce/reduce.d",
			stdin, stdout, stderr, null, Config.none, tests[0]
		).wait();
		enforce(status == 0, "reduce build failed with status %s".format(status));
	}

	auto mutex = new Object;

	foreach (test; tests.parallel)
	{
		scope(failure) stderr.writefln("runtests: Error with test %s", test);

		string base, target;

		if (exists(test ~ "/src"))
			base = target = "src";
		else
		if (exists(test ~ "/src.d"))
			base = target = "src.d";
		else
		if (exists(test ~ "/stdin"))
			base = "stdin", target = "-";
		else
		if (exists(test ~ "/src.json"))
			base = target = "src.json";
		else
			base = "src", target = null;
		version (Windows)
			enum testFile = "oracle.cmd";
		else
			enum testFile = "oracle.sh";
		auto tester = test ~ "/" ~ testFile;
		auto testerCmd = ".." ~ dirSeparator ~ testFile;

		base = test ~ "/" ~ base;
		auto tempDir = base ~ ".temp";
		if (tempDir.exists) tempDir.rmdirRecurse();
		auto reducedDir = base ~ ".reduced";
		if (reducedDir.exists) reducedDir.rmdirRecurse();
		auto resultDir = base ~ ".result";
		if (resultDir.exists) resultDir.rmdirRecurse();
		auto cacheDir = base ~ ".cache";
		if (cacheDir.exists) cacheDir.rmdirRecurse();

		string[] opts;
		auto optsFile = test ~ "/args.txt";
		if (optsFile.exists)
			opts = optsFile.readText().splitLines();
		if (opts.canFind("--in-place"))
		{
			copyRecurse(test ~ "/" ~ target, reducedDir);
			target = reducedDir.baseName;
		}

		File input() { return target == "-" ? File(base, "rb") : stdin; }

		auto outputFile = test~"/output.txt";
		File output;
		synchronized(mutex) output.open(outputFile, "wb");

		stderr.writefln("runtests: test %s: dumping", test);
		auto status = spawnProcess([reduce] ~ opts ~ (target ? ["--dump", "--no-optimize", target] : []),
			input, output, output, null, Config.retainStdout | Config.retainStderr, test).wait();
		enforce(status == 0, "reduce dump failed with status %s".format(status));
		stderr.writefln("runtests: test %s: done", test);

		stderr.writefln("runtests: test %s: dumping JSON", test);
		status = spawnProcess([reduce] ~ opts ~ (target ? ["--dump-json", "--no-optimize", target] : []),
			input, output, output, null, Config.retainStdout | Config.retainStderr, test).wait();
		enforce(status == 0, "reduce JSON dump failed with status %s".format(status));
		stderr.writefln("runtests: test %s: done", test);

		if (!tester.exists)
			continue; // dump only

		synchronized(mutex) output.reopen(outputFile, "ab"); // Reopen because spawnProcess closes it
		stderr.writefln("runtests: test %s: reducing", test);
		status = spawnProcess([reduce] ~ opts ~ ["--times", target, testerCmd],
			input, output, output, null, Config.retainStdout | Config.retainStderr, test).wait();
		enforce(status == 0, "reduce run failed with status %s".format(status));
		stderr.writefln("runtests: test %s: done", test);

		rename(reducedDir, resultDir);
		synchronized(mutex) output.close();
		auto progress = File(test~"/progress.txt", "wb");
		foreach (line; File(outputFile, "rb").byLine())
		{
			line = line.strip();
			if (line.startsWith("[") || line.startsWith("#") || line.startsWith("=") || line.startsWith("ReplaceWord"))
				progress.writeln(line);
			else
			if (line.startsWith("Done in "))
				progress.writeln(line.split()[0..4].join(" "));
		}
	}
}

void copyRecurse(string from, string to)
{
	mkdir(to);
	foreach (de; dirEntries(from, SpanMode.breadth))
	{
		auto target = to.buildPath(de.name.absolutePath.relativePath(from.absolutePath));
		if (de.isDir)
			mkdir(target);
		else
			copy(de.name, target);
	}
}
