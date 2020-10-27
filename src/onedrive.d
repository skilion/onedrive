import std.algorithm: min;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.json;
import std.path;
import std.stdio;
import std.string;
import std.uri;
import std.net.curl;
import config;
static import log;


private immutable {
	string clientId = "22c49a0d-d21c-4792-aed1-8f163c982546";
	string authUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
	string redirectUrl = "https://login.microsoftonline.com/common/oauth2/nativeclient";
	string tokenUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
	string driveUrl = "https://graph.microsoft.com/v1.0/me/drive";
	string itemByIdUrl = "https://graph.microsoft.com/v1.0/me/drive/items/";
	string itemByPathUrl = "https://graph.microsoft.com/v1.0/me/drive/root:/";
	string driveByIdUrl = "https://graph.microsoft.com/v1.0/drives/";
}

version(unittest)
{
	private OneDriveApi buildOneDriveApi()
	{
		string configDirName = expandTilde("~/.config/onedrive");
		auto cfg = new config.Config(configDirName);
		cfg.init();
		OneDriveApi onedrive = new OneDriveApi(cfg);
		onedrive.init();
		return onedrive;
	}
}

class OneDriveException: Exception
{
	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/concepts/errors
	int httpStatusCode;
	JSONValue error;

	@safe pure this(int httpStatusCode, string reason, string file = __FILE__, size_t line = __LINE__)
	{
		this.httpStatusCode = httpStatusCode;
		this.error = error;
		string msg = format("HTTP request returned status code %d (%s)", httpStatusCode, reason);
		super(msg, file, line);
	}

	this(int httpStatusCode, string reason, ref const JSONValue error, string file = __FILE__, size_t line = __LINE__)
	{
		this.httpStatusCode = httpStatusCode;
		this.error = error;
		string msg = format("HTTP request returned status code %d (%s)\n%s", httpStatusCode, reason, toJSON(error, true));
		super(msg, file, line);
	}
}

final class OneDriveApi
{
	private Config cfg;
	private string refreshToken, accessToken;
	private SysTime accessTokenExpiration;
	/* private */ HTTP http;

	// if true, every new access token is printed
	bool printAccessToken;

	this(Config cfg)
	{
		this.cfg = cfg;
		http = HTTP();
		//http.verbose = true;
	}

	bool init()
	{
		try {
			refreshToken = readText(cfg.refreshTokenFilePath);
		} catch (FileException e) {
			return authorize();
		}
		return true;
	}

	bool authorize()
	{
		import std.stdio, std.regex;
		char[] response;
		string url = authUrl ~ "?client_id=" ~ clientId ~ "&scope=files.readwrite%20files.readwrite.all%20offline_access&response_type=code&redirect_uri=" ~ redirectUrl;
		log.log("Authorize this app visiting:\n");
		write(url, "\n\n", "Enter the response uri: ");
		readln(response);
		// match the authorization code
		auto c = matchFirst(response, r"(?:[\?&]code=)([\w\d-.]+)");
		if (c.empty) {
			log.log("Invalid uri");
			return false;
		}
		c.popFront(); // skip the whole match
		redeemToken(c.front);
		return true;
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/drive_get
	JSONValue getDefaultDrive()
	{
		checkAccessTokenExpired();
		return get(driveUrl);
	}

	unittest
	{
		OneDriveApi onedrive = buildOneDriveApi();
		auto drive = onedrive.getDefaultDrive();
		assert("id" in drive);
		assert("quota" in drive);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getDefaultRoot()
	{
		checkAccessTokenExpired();
		return get(driveUrl ~ "/root");
	}

	unittest
	{
		OneDriveApi onedrive = buildOneDriveApi();
		auto root = onedrive.getDefaultRoot();
		assert("id" in root);
		assert("root" in root);
		assert("folder" in root);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get
	JSONValue getItemByPath(const(char)[] path)
	{
		checkAccessTokenExpired();
		const(char)[] url = itemByPathUrl ~ encodeComponent(path);
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delta
	JSONValue viewChangesById(const(char)[] driveId, const(char)[] id, const(char)[] deltaLink)
	{
		checkAccessTokenExpired();
		const(char)[] url = deltaLink;
		if (url == null) {
			url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/delta";
			url ~= "?select=id,name,eTag,cTag,deleted,file,folder,root,fileSystemInfo,remoteItem,parentReference";
		}
		return get(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_get_content
	void downloadById(const(char)[] driveId, const(char)[] id, string saveToPath)
	{
		checkAccessTokenExpired();
		scope(failure) {
			if (exists(saveToPath)) remove(saveToPath);
		}
		mkdirRecurse(dirName(saveToPath));
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/content?AVOverride=1";
		download(url, saveToPath);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_put_content
	JSONValue simpleUpload(string localPath, string driveId, string parentId, string filename, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		string url = driveByIdUrl ~ driveId ~ "/items/" ~ parentId ~ ":/" ~ encodeComponent(filename) ~ ":/content";
		if (eTag) http.addRequestHeader("if-match", eTag);
		return upload(url, localPath);
	}

	unittest
	{
		OneDriveApi onedrive = buildOneDriveApi();
		string driveId = onedrive.getDefaultDrive()["id"].str;
		string rootId = onedrive.getDefaultRoot["id"].str;

		collectException(onedrive.deleteByPath("test"));

		std.file.write("/tmp/test", "test");
		auto item = onedrive.simpleUpload("/tmp/test", driveId, rootId, "test");

		try {
			onedrive.simpleUpload("/tmp/test", driveId, rootId, "test", "123");
		} catch (OneDriveException e) {
			assert(e.httpStatusCode == 412);
		}
		onedrive.simpleUpload("/tmp/test", driveId, rootId, "test", item["eTag"].str);

		collectException(onedrive.deleteByPath("test"));
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_put_content
	JSONValue simpleUploadReplace(string localPath, string driveId, string id, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		string url = driveByIdUrl ~ driveId ~ "/items/" ~ id ~ "/content";
		if (eTag) http.addRequestHeader("If-Match", eTag);
		return upload(url, localPath);
	}

	unittest
	{
		OneDriveApi onedrive = buildOneDriveApi();
		string driveId = onedrive.getDefaultDrive()["id"].str;
		string rootId = onedrive.getDefaultRoot["id"].str;

		collectException(onedrive.deleteByPath("test"));

		std.file.write("/tmp/test", "test");
		auto item = onedrive.simpleUpload("/tmp/test", driveId, rootId, "test");

		try {
			onedrive.simpleUploadReplace("/tmp/test", driveId, item["id"].str, "123");
		} catch (OneDriveException e) {
			assert(e.httpStatusCode == 412);
		}
		onedrive.simpleUploadReplace("/tmp/test", driveId, item["id"].str, item["eTag"].str);

		collectException(onedrive.deleteByPath("test"));
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_update
	JSONValue updateById(const(char)[] driveId, const(char)[] id, JSONValue data, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		if (eTag) http.addRequestHeader("If-Match", eTag);
		http.addRequestHeader("Content-Type", "application/json");
		return patch(url, data.toString());
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_delete
	void deleteById(const(char)[] driveId, const(char)[] id, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ id;
		if (eTag) http.addRequestHeader("if-match", eTag);
		del(url);
	}

	unittest
	{
		OneDriveApi onedrive = buildOneDriveApi();
		string driveId = onedrive.getDefaultDrive()["id"].str;
		string rootId = onedrive.getDefaultRoot["id"].str;

		collectException(onedrive.deleteByPath("test"));

		std.file.write("/tmp/test", "test");
		auto item = onedrive.simpleUpload("/tmp/test", driveId, rootId, "test");

		try {
			onedrive.deleteById(driveId, item["id"].str, "123");
		} catch (OneDriveException e) {
			assert(e.httpStatusCode == 412);
		}
		onedrive.deleteById(driveId, item["id"].str, item["eTag"].str);

		collectException(onedrive.deleteByPath("test"));
	}

	void deleteByPath(const(char)[] path)
	{
		checkAccessTokenExpired();
		auto url = itemByPathUrl ~ encodeComponent(path);
		del(url);
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_post_children
	JSONValue createById(const(char)[] parentDriveId, const(char)[] parentId, JSONValue item)
	{
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ "/children";
		http.addRequestHeader("Content-Type", "application/json");
		return post(url, item.toString());
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_post_children
	JSONValue createFolder(const(char)[] driveId, const(char)[] parentId, const(char)[] name)
	{
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ driveId ~ "/items/" ~ parentId ~ "/children";
		http.addRequestHeader("Content-Type", "application/json");
		JSONValue item = [
			"name": JSONValue(name),
			"folder": JSONValue(cast(int[string]) null)
		];
		return post(url, item.toString());
	}

	unittest
	{
		OneDriveApi onedrive = buildOneDriveApi();
		string driveId = onedrive.getDefaultDrive()["id"].str;
		string rootId = onedrive.getDefaultRoot["id"].str;

		collectException(onedrive.deleteByPath("test"));

		onedrive.createFolder(driveId, rootId, "test");

		try {
			onedrive.createFolder(driveId, rootId, "test");
		} catch (OneDriveException e) {
			assert(e.httpStatusCode == 409);
		}

		collectException(onedrive.deleteByPath("test"));
	}

	// https://docs.microsoft.com/en-us/onedrive/developer/rest-api/api/driveitem_createuploadsession
	JSONValue createUploadSession(const(char)[] parentDriveId, const(char)[] parentId, const(char)[] filename, const(char)[] eTag = null)
	{
		checkAccessTokenExpired();
		const(char)[] url = driveByIdUrl ~ parentDriveId ~ "/items/" ~ parentId ~ ":/" ~ encodeComponent(filename) ~ ":/createUploadSession";
		if (eTag) http.addRequestHeader("If-Match", eTag);
		return post(url, null);
	}

	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue uploadFragment(const(char)[] uploadUrl, string filepath, long offset, long fragmentSize, long fileSize)
	{
		checkAccessTokenExpired();
		string contentRange = "bytes " ~ to!string(offset) ~ "-" ~ to!string(offset + fragmentSize - 1) ~ "/" ~ to!string(fileSize);
		http.addRequestHeader("Content-Range", contentRange);
		return upload(uploadUrl, filepath, offset, fragmentSize);
	}

	// https://dev.onedrive.com/items/upload_large_files.htm
	JSONValue requestUploadStatus(const(char)[] uploadUrl)
	{
		checkAccessTokenExpired();
		return get(uploadUrl);
	}

	private void redeemToken(const(char)[] authCode)
	{
		const(char)[] postData =
			"client_id=" ~ clientId ~
			"&redirect_uri=" ~ redirectUrl ~
			"&code=" ~ authCode ~
			"&grant_type=authorization_code";
		acquireToken(postData);
	}

	private void newToken()
	{
		string postData =
			"client_id=" ~ clientId ~
			"&redirect_uri=" ~ redirectUrl ~
			"&refresh_token=" ~ refreshToken ~
			"&grant_type=refresh_token";
		acquireToken(postData);
	}

	private void acquireToken(const(char)[] postData)
	{
		JSONValue response = post(tokenUrl, postData);
		accessToken = "bearer " ~ response["access_token"].str();
		refreshToken = response["refresh_token"].str();
		accessTokenExpiration = Clock.currTime() + dur!"seconds"(response["expires_in"].integer());
		std.file.write(cfg.refreshTokenFilePath, refreshToken);
		if (printAccessToken) writeln("New access token: ", accessToken);
	}

	private void checkAccessTokenExpired()
	{
		try {
			if (Clock.currTime() >= accessTokenExpiration) {
				newToken();
			}
		} catch (OneDriveException e) {
			if (e.httpStatusCode == 400 || e.httpStatusCode == 401) {
				e.msg ~= "\nRefresh token invalid, use --logout to authorize the client again";
			}
			throw e;
		}
	}

	private void addAccessTokenHeader()
	{
		http.addRequestHeader("Authorization", accessToken);
	}

	private JSONValue get(const(char)[] url)
	{
		http.method = HTTP.Method.get;
		http.url = url;
		return perform();
	}

	private void del(const(char)[] url)
	{
		http.method = HTTP.Method.del;
		http.url = url;
		perform();
	}

	private void download(const(char)[] url, string outfile)
	{
		http.method = HTTP.Method.get;
		http.url = url;
		perform(outfile);
	}

	private auto patch(const(char)[] url, const(void)[] patchData)
	{
		http.method = HTTP.Method.patch;
		http.url = url;
		setContent(patchData);
		return perform();
	}

	private auto post(const(char)[] url, const(void)[] postData)
	{
		http.method = HTTP.Method.post;
		http.url = url;
		setContent(postData);
		return perform();
	}

	private JSONValue upload(const(char)[] url, string filepath, long offset = 0, long contentLength = 0)
	{
		http.method = HTTP.Method.put;
		http.url = url;
		http.addRequestHeader("Content-Type", "application/octet-stream");
		auto file = File(filepath, "rb");
		file.seek(offset);
		http.onSend = data => file.rawRead(data).length;
		http.contentLength = contentLength <= 0 ? file.size : contentLength;
		return perform();
	}

	private void setContent(const(void)[] data)
	{
		http.contentLength = data.length;
		http.onSend = (void[] buf) {
			auto length = min(buf.length, data.length);
			buf[0 .. length] = data[0 .. length];
			data = data[length .. $];
			return length;
		};
	}

	private JSONValue perform()
	{
		scope(exit) {
			http.contentLength = 0;
			http.onReceive = null;
			http.onSend = null;
			http.clearRequestHeaders();
		}
		scope(failure) {
			http = HTTP();
		}

		addAccessTokenHeader();

		char[] content;
		http.onReceive = (ubyte[] data) {
			content ~= data;
			return data.length;
		};

		http.perform();

		auto json = parseJson(content);
		checkHttpCode(json);

		return json;
	}

	private void perform(string outfile)
	{
		scope(exit) {
			http.contentLength = 0;
			http.onReceive = null;
			http.onSend = null;
			http.clearRequestHeaders();
		}
		scope(failure) {
			http = HTTP();
		}

		addAccessTokenHeader();

		auto f = File(outfile, "wb");
		http.onReceive = (ubyte[] data) {
			f.rawWrite(data);
			return data.length;
		};

		http.perform();
		checkHttpCode();
	}

	private JSONValue parseJson(const(char)[] str)
	{
		JSONValue json;
		try {
			json = parseJSON(str);
		} catch (JSONException e) {
			e.msg ~= "\n";
			e.msg ~= str;
			throw e;
		}
		return json;
	}

	private void checkHttpCode()
	{
		if (http.statusLine.code / 100 != 2) {
			throw new OneDriveException(http.statusLine.code, http.statusLine.reason);
		}
	}

	private void checkHttpCode(ref const JSONValue response)
	{
		if (http.statusLine.code / 100 != 2) {
			throw new OneDriveException(http.statusLine.code, http.statusLine.reason, response);
		}
	}
}
