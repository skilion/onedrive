import std.algorithm;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.stdio;
import config, onedrive;

string syncDir = "sync/";
string onedriveConfigDir = "config/";
string onedriveExe = "../onedrive";
string driveId;
string rootId;

config.Config onedriveConfig;
OneDriveApi oapi;


void main()
{
	oapi = buildOneDriveApi();
	driveId = oapi.getDefaultDrive()["id"].str;
	rootId = oapi.getDefaultRoot["id"].str;

	reset();
	testDownloadChanges();
}

private OneDriveApi buildOneDriveApi()
{
	mkdirRecurse(onedriveConfigDir);
	onedriveConfig = new config.Config(onedriveConfigDir);
	onedriveConfig.init();
	OneDriveApi onedrive = new OneDriveApi(onedriveConfig);
	onedrive.init();
	return onedrive;
}

private void reset()
{
	writeln("reset()");
	collectException(oapi.deleteByPath("foo"));
	collectException(oapi.deleteByPath("bar"));
	if (exists(syncDir)) rmdirRecurse(syncDir);
	if (exists(onedriveConfig.syncListFilePath)) remove(onedriveConfig.syncListFilePath);
	sync(true);
}

private void sync(bool resync = false)
{
	std.stdio.write("Syncing...");
	auto cmd = [onedriveExe, "--confdir", onedriveConfigDir, "--syncdir", syncDir, "--verbose"];
	if (resync) {
		cmd ~= "--resync";
	}
	auto result = execute(cmd);
	std.file.write("last_sync.log", result.output);
	assert(result.status == 0, "Sync failed, check last_sync.log");
	writeln(" done");
}

private void testDownloadChanges()
{
	testDownloadChangesFiltered();
	testDownloadChangesCreateFolders();
	testDownloadChangesDeletion();
	string parentId = testDownloadChangesCreateFile();
	testDownloadChangesEditFile(parentId);
}

private void testDownloadChangesFiltered()
{
	writeln("testDownloadChangesFiltered()");

	// arrange
	oapi.createFolder(driveId, rootId, "foo");
	oapi.createFolder(driveId, rootId, "bar");
	std.file.write(onedriveConfigDir ~ "sync_list", "foo");

	// act
	sync();

	// assert
	assert(isDir(syncDir ~ "foo"));
	assert(!exists(syncDir ~ "bar"));

	// clean up
	oapi.deleteByPath("foo");
	oapi.deleteByPath("bar");
	remove(onedriveConfig.syncListFilePath);
}

private void testDownloadChangesCreateFolders()
{
	writeln("testDownloadChangesCreateFolders()");

	// arrange
	auto foo = oapi.createFolder(driveId, rootId, "foo");
	oapi.createFolder(driveId, foo["id"].str, "bar");

	// act
	sync();

	// assert
	assert(isDir(syncDir ~ "foo"));
	assert(isDir(syncDir ~ "foo/bar"));
}

private void testDownloadChangesDeletion()
{
	writeln("testDownloadChangesDeletion()");

	// arrange
	oapi.deleteByPath("foo");

	// act
	sync();

	// assert
	assert(!exists(syncDir ~ "foo"));
}

private string testDownloadChangesCreateFile()
{
	writeln("testDownloadChangesCreateFile()");

	// arrange
	std.file.write("/tmp/bar", "bar");
	auto foo = oapi.createFolder(driveId, rootId, "foo");
	auto bar = oapi.simpleUpload("/tmp/bar", driveId, foo["id"].str, "bar");

	// act
	sync();

	// assert
	assert(isDir(syncDir ~ "foo"));
	assert(isFile(syncDir ~ "foo/bar"));

	return foo["id"].str;
}

private void testDownloadChangesEditFile(string parentId)
{
	writeln("testDownloadChangesEditFile()");

	// arrange
	std.file.write("/tmp/bar", "foo");
	auto bar = oapi.simpleUpload("/tmp/bar", driveId, parentId, "bar");

	// act
	sync();
	string text = readText(syncDir ~ "foo/bar");

	// assert
	assert(equal(text, "foo"));
}