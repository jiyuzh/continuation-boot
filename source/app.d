import std.stdio;
import std.conv : to;

//
// Argument parser
//

auto showHelp()
{
	auto document = `continuation-boot

NAME
	continuation-boot - automatic kernel selection and evaluation continuation tool

SYNOPSIS
	continuation-boot ENTRY_PATTERN [ENTRY_OFFSET] [-- COMMAND]

DESCRIPTION
	Select the next-boot kernel based on input, and execute a command on next startup.

	ENTRY_PATTERN is a PCRE regular expression pattern. It is matched against the human-readable name and full qualified name of the boot entries. Matched boot entries will be considered for next boot.

	ENTRY_OFFSET is an integer. If multiple boot entries can be matched with ENTRY_PATTERN, the offset will be used to select the desired one. Count from zero. Optional.

	COMMAND is the command to be executed. You may provide arguments for the command as well. It will run in $PWD as root user. Optional.
`;
	writeln(document);
}

struct Options
{
	bool error;
	string pattern;
	int offset;
	string command;
}

auto parseArguments(string[] args)
{
	import std.exception : ifThrown;
	import std.process : escapeShellCommand;

	Options options;
	options.error = true;
	options.offset = 0;
	options.command = "";

	if (args.length < 1) {
		showHelp();
		return options;
	}

	options.pattern = args[0];

	// no offset and cmd
	if (args.length < 2) {
		options.error = false;
		return options;
	}

	auto cmdPart = 1;

	// parse optional offset
	if (args[1] != "--") {
		options.offset = args[1].to!int.ifThrown(-1);

		// array index cannot be negative or invalid
		if (options.offset < 0) {
			writeln("Invalid ENTRY_OFFSET: " ~ args[1]);
			return options;
		}

		cmdPart = 2;
	}

	// no cmd
	if (args.length < cmdPart + 1) {
		options.error = false;
		return options;
	}

	// parse optional arguments
	if (args[cmdPart] != "--") {
		writeln("Unrecognized argument: " ~ args[cmdPart]);
		return options;
	}

	// no cmd body
	if (args.length < cmdPart + 2) {
		writeln("Missing command line");
		return options;
	}

	options.command = escapeShellCommand(["/usr/bin/env", "bash", "-c"] ~ args[cmdPart + 1 .. $]);

	options.error = false;
	return options;
}

//
// Grub parser
//

void push(T)(ref T[] xs, T x) {
	xs ~= x;
}

T pop(T)(ref T[] xs) {
	T x = xs[$ - 1];
	--xs.length;
	return x;
}

struct GrubCfgItem
{
	string name;
	string[] id;
}

auto parseGrubCfg(string path)
{
	import std.file : readText;
	import std.regex : ctRegex, matchAll;

	writeln("Parsing GRUB config file: " ~ path);

	auto file = path.readText();
	auto pattern = ctRegex!(`^\s*(?P<class>menuentry|submenu)\s+'(?P<name>[^']+)'\s+[^']+\s+'(?P<id>[^']+)'\s`, "gm");
	string[] stack;
	GrubCfgItem[] result;

	auto items = file.matchAll(pattern);
	auto cursor = "ERR_SUBMENU_NULL";

	ulong i = 0;
	foreach (item; items) {
		for (; i < item.pre.length; i++) {
			auto ch = file[i];

			switch (ch) {
			case '{':
				stack.push(cursor);
				cursor = "ERR_SUBMENU_NULL";
				break;
			case '}':
				cursor = stack.pop();
				break;
			default:
				break;
			}
		}

		if (item["class"] == "submenu") {
			cursor = item["id"];
		}

		if (item["class"] == "menuentry") {
			auto entry = GrubCfgItem();

			entry.name = item["name"];
			entry.id = stack;
			entry.id ~= item["id"];

			result ~= entry;
		}
	}

	writeln("\tLoaded " ~ result.length.to!string ~ " bootable entries");

	return result;
}

auto filterGrubEntry(GrubCfgItem[] list, string pattern)
{
	import std.array : join;
	import std.regex : regex, matchFirst;

	writeln("Filtering entries with PCRE pattern: /" ~ pattern ~ "/gm");

	auto matcher = regex(pattern, "gm");
	GrubCfgItem[] matched;

	foreach (item; list) {
		if (!item.name.matchFirst(matcher).empty) {
			matched ~= item;
			continue;
		}

		auto fqn = item.id.join(">");

		if (!fqn.matchFirst(matcher).empty) {
			matched ~= item;
			continue;
		}
	}

	writeln("\tGathered " ~ matched.length.to!string ~ " bootable entries:");
	foreach (i, match; matched) {
		writeln("\t\t[" ~ i.to!string ~ "] " ~ match.name);
	}

	return matched;
}

auto selectGrubBoot(GrubCfgItem item)
{
	import std.array : join;
	import std.process : execute;

	auto fqn = item.id.join(">");
	auto ret = execute(["grub-reboot", fqn]);
	auto success = ret.status == 0;

	if (success) {
		writeln("Set boot entry to:" ~ 
			"\n\tHuman name: " ~ item.name ~
			"\n\tGRUB name: " ~ fqn
		);
	}
	else {
		writeln("Failed to set boot entry to:" ~ 
			"\n\tHuman name: " ~ item.name ~
			"\n\tGRUB name: " ~ fqn ~
			"\n\tReturn code: " ~ ret.status.to!string
		);
	}

	return success;
}

//
// Systemd configurator
//

auto deploySystemdService(string path, string pwd, string cmd)
{
	import std.algorithm.searching : startsWith;
	import std.file : exists, readText, write;
	import std.path : baseName, buildNormalizedPath;

	writeln("Deploying invoker service descriptor");

	if (path.exists()) {
		writeln("\tChecking invoker service descriptor");

		auto text = path.readText();

		if (!text.startsWith("# continuation-boot version 1\n")) {
			writeln("\tOverwriting existed service is prohibited: " ~ path);
			return false;
		}
	}

	auto text = `# continuation-boot version 1

[Unit]
Description=Continuation boot invoker service
After=syslog.target network.target multi-user.target

[Service]
User=root
WorkingDirectory=` ~ buildNormalizedPath(pwd) ~ `
ExecStartPre=/bin/sleep 30
ExecStart=` ~ cmd ~ `
ExecStartPost=systemctl disable ` ~ path.baseName() ~ `

[Install]
WantedBy=multi-user.target
`;

	writeln("\tWriting invoker service descriptor");
	write(path, text);

	return true;
}

auto enableSystemdService(string path)
{
	import std.process : execute;
	import std.path : baseName;

	auto ret = execute(["systemctl", "enable", path.baseName()]);
	auto success = ret.status == 0;

	if (success) {
		writeln("Enabled service descrptor" ~ 
			"\n\tPath: " ~ path
		);
	}
	else {
		writeln("Failed to enable service descrptor" ~ 
			"\n\tPath: " ~ path ~
			"\n\tReturn code: " ~ ret.status.to!string
		);
	}

	return success;
}

auto main(string[] args)
{
	import std.exception : ifThrown;
	import std.file : getcwd;

	auto options = parseArguments(args[1 .. $]);
	if (options.error) {
		return 1;
	}

	auto grubCfg = `/boot/grub/grub.cfg`;
	auto serviceFile = `/etc/systemd/system/continuation-boot.service`;
	auto basePath = getcwd();

	writeln("Job received:" ~
		"\n\tPattern: /" ~ options.pattern ~ "/gm" ~
		"\n\tOffset: " ~ options.offset.to!string ~
		"\n\tCommand: " ~ options.command ~
		"\n\tWorking directory: " ~ basePath
	);

	// grub

	auto entries = parseGrubCfg(grubCfg).ifThrown(null);
	auto matches = filterGrubEntry(entries, options.pattern).ifThrown(null);
	if (matches.length < options.offset + 1) {
		writeln("Boot entry not found at offset " ~ options.offset.to!string);
		return 1;
	}
	if (!selectGrubBoot(matches[options.offset]).ifThrown(false)) {
		return 1;
	}

	// no command, quit
	if (options.command.length == 0) {
		writeln("Done");
		return 0;
	}

	// systemd

	if (!deploySystemdService(serviceFile, basePath, options.command).ifThrown(false)) {
		return 1;
	}
	if (!enableSystemdService(serviceFile).ifThrown(false)) {
		return 1;
	}

	writeln("Done");
	return 0;
}
