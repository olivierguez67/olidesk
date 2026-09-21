// DeployConfig.cpp — the two custom actions behind the deployment
// device-registration prompt (Package/UI/DeployConfigDlg.wxs):
//
//  - FetchGroups: immediate CA, runs when "Next" is clicked on
//    MyInstallDirDlg (before DeployConfigDlg is shown). GETs
//    {API_URL}/api/deploy/groups with the baked-in deploy token and
//    populates the GROUP combo box's ComboBox table rows at runtime. Not
//    /api/groups: that's the admin endpoint, gated by per-device admin
//    auth, and 401s for a deploy token. Never blocks or fails the install:
//    on any error (unreachable server, timeout, bad response) it just
//    logs and leaves the combo box empty, which is still a usable
//    free-text field since it isn't list-restricted.
//
//  - WriteDeployJson: deferred CA, runs after InstallFiles. Writes
//    olidesk-deploy.json into the install folder from DEVICENAME, GROUP,
//    and the baked-in API_URL/DEPLOY_TOKEN, so the app can self-register on
//    first launch (flutter/lib/common/olidesk_deploy.dart) instead of
//    needing that file dropped in by hand after install. Refuses to write
//    a GROUP value that looks like an unresolved MSI ComboBox placeholder
//    ("#TEMPnnnn") or a known internal status string ("GROUPS_LOADED",
//    "DEPLOY_GROUPS_STATUS", "LOADED") -- see the comment where it's
//    checked below.
//
// Both are compiled in only when the installer was built with
// --api-url/--deploy-token (see ../preprocess.py and the `<?ifdef ApiUrl?>`
// guards throughout the Package/*.wxs files) -- i.e. the client build, not
// the admin build.

#include "pch.h"
#include <winhttp.h>
#include <strutil.h>
#include <string>
#include <vector>
#include <sstream>

#include "./Common.h"

#pragma comment(lib, "winhttp.lib")

namespace {

// ---------------------------------------------------------------------
// UTF-8 / UTF-16 conversion
// ---------------------------------------------------------------------

std::string WideToUtf8(const std::wstring& wide)
{
    if (wide.empty()) return std::string();
    int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), NULL, 0, NULL, NULL);
    if (size <= 0) return std::string();
    std::string result(size, 0);
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), &result[0], size, NULL, NULL);
    return result;
}

std::wstring Utf8ToWide(const std::string& utf8)
{
    if (utf8.empty()) return std::wstring();
    int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), NULL, 0);
    if (size <= 0) return std::wstring();
    std::wstring result(size, 0);
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), &result[0], size);
    return result;
}

// ---------------------------------------------------------------------
// Minimal JSON handling
//
// Not a general-purpose parser: just enough to (a) parse a JSON string
// literal with escapes, used both to read the groups response and to
// extract "name" values from it, and (b) escape a string for the JSON we
// write out. Sufficient because we're parsing our own server's
// well-formed, server-controlled response shape, not arbitrary JSON.
// ---------------------------------------------------------------------

bool ParseJsonStringLiteral(const std::string& s, size_t& i, std::string& out)
{
    if (i >= s.size() || s[i] != '"') return false;
    i++;
    out.clear();
    while (i < s.size())
    {
        char c = s[i];
        if (c == '"')
        {
            i++;
            return true;
        }
        if (c == '\\')
        {
            i++;
            if (i >= s.size()) return false;
            char esc = s[i];
            switch (esc)
            {
            case '"': out += '"'; i++; break;
            case '\\': out += '\\'; i++; break;
            case '/': out += '/'; i++; break;
            case 'b': out += '\b'; i++; break;
            case 'f': out += '\f'; i++; break;
            case 'n': out += '\n'; i++; break;
            case 'r': out += '\r'; i++; break;
            case 't': out += '\t'; i++; break;
            case 'u':
            {
                if (i + 5 > s.size()) return false;
                std::string hex = s.substr(i + 1, 4);
                wchar_t code = (wchar_t)wcstol(Utf8ToWide(hex).c_str(), nullptr, 16);
                wchar_t wch[2] = { code, 0 };
                out += WideToUtf8(wch);
                i += 5;
                break;
            }
            default:
                return false;
            }
        }
        else
        {
            out += c;
            i++;
        }
    }
    return false; // unterminated string
}

// Extracts every top-level JSON string from a flat array like
// ["Group A","Group B"], which is exactly what GET /api/deploy/groups
// returns (see list_deploy_groups in olidesk-api/app.py): plain top-level
// group names, no nesting, no other fields. A simple "every string
// literal is a value" scan is correct for that shape without needing a
// general-purpose parser.
std::vector<std::wstring> ExtractJsonStringArray(const std::string& json)
{
    std::vector<std::wstring> values;
    size_t i = 0;
    while (i < json.size())
    {
        if (json[i] == '"')
        {
            std::string value;
            if (!ParseJsonStringLiteral(json, i, value))
            {
                break; // malformed; keep whatever we already found
            }
            values.push_back(Utf8ToWide(value));
        }
        else
        {
            i++;
        }
    }
    return values;
}

std::wstring JsonEscape(const std::wstring& in)
{
    std::wstring out;
    out.reserve(in.size());
    for (wchar_t c : in)
    {
        switch (c)
        {
        case L'"': out += L"\\\""; break;
        case L'\\': out += L"\\\\"; break;
        case L'\n': out += L"\\n"; break;
        case L'\r': out += L"\\r"; break;
        case L'\t': out += L"\\t"; break;
        default:
            if (c < 0x20)
            {
                wchar_t buf[8];
                swprintf_s(buf, L"\\u%04x", c);
                out += buf;
            }
            else
            {
                out += c;
            }
        }
    }
    return out;
}

// ---------------------------------------------------------------------
// HTTPS GET via WinHTTP
// ---------------------------------------------------------------------

// Returns true and fills outBody (UTF-8) on HTTP 200; false on anything
// else (unreachable, timeout, TLS failure, non-200, ...). outStatusCode is
// always set when a response was received at all (0 if the request never
// got that far, e.g. DNS/connect failure) and is always logged, success
// or failure, so a 401/403/etc is visible without needing to reproduce it.
// Bounded timeouts so a dead or slow server can never hang the installer
// -- "install never blocks" is the whole point of the fallback requirement.
bool HttpsGetJson(const std::wstring& url, const std::wstring& bearerToken, std::string& outBody, DWORD& outStatusCode)
{
    bool ok = false;
    outStatusCode = 0;

    URL_COMPONENTS urlComp;
    ZeroMemory(&urlComp, sizeof(urlComp));
    urlComp.dwStructSize = sizeof(urlComp);
    wchar_t hostName[256] = { 0 };
    wchar_t urlPath[2048] = { 0 };
    urlComp.lpszHostName = hostName;
    urlComp.dwHostNameLength = ARRAYSIZE(hostName);
    urlComp.lpszUrlPath = urlPath;
    urlComp.dwUrlPathLength = ARRAYSIZE(urlPath);

    if (!WinHttpCrackUrl(url.c_str(), (DWORD)url.size(), 0, &urlComp))
    {
        WcaLog(LOGMSG_STANDARD, "FetchGroups: failed to parse API URL, error %lu", GetLastError());
        return false;
    }

    bool useHttps = (urlComp.nScheme == INTERNET_SCHEME_HTTPS);

    HINTERNET hSession = WinHttpOpen(L"Olidesk-Installer/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession)
    {
        WcaLog(LOGMSG_STANDARD, "FetchGroups: WinHttpOpen failed, error %lu", GetLastError());
        return false;
    }

    // Resolve/connect/send/receive timeouts, in milliseconds.
    WinHttpSetTimeouts(hSession, 5000, 5000, 8000, 8000);

    HINTERNET hConnect = WinHttpConnect(hSession, urlComp.lpszHostName, urlComp.nPort, 0);
    if (!hConnect)
    {
        WcaLog(LOGMSG_STANDARD, "FetchGroups: WinHttpConnect failed, error %lu", GetLastError());
        WinHttpCloseHandle(hSession);
        return false;
    }

    DWORD flags = useHttps ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hRequest = WinHttpOpenRequest(hConnect, L"GET", urlComp.lpszUrlPath,
        NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!hRequest)
    {
        WcaLog(LOGMSG_STANDARD, "FetchGroups: WinHttpOpenRequest failed, error %lu", GetLastError());
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        return false;
    }

    std::wstring header = L"Authorization: Bearer " + bearerToken;
    WinHttpAddRequestHeaders(hRequest, header.c_str(), (DWORD)header.size(), WINHTTP_ADDREQ_FLAG_ADD);

    BOOL sent = WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
        WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    if (sent && WinHttpReceiveResponse(hRequest, NULL))
    {
        DWORD statusCode = 0;
        DWORD statusCodeSize = sizeof(statusCode);
        WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_FLAG_NUMBER | WINHTTP_QUERY_STATUS_CODE,
            WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &statusCodeSize, WINHTTP_NO_HEADER_INDEX);

        outStatusCode = statusCode;
        WcaLog(LOGMSG_STANDARD, "FetchGroups: HTTP status %lu", statusCode);

        if (statusCode == 200)
        {
            std::string body;
            DWORD available = 0;
            do
            {
                available = 0;
                if (!WinHttpQueryDataAvailable(hRequest, &available)) break;
                if (available == 0) break;
                std::vector<char> buffer(available);
                DWORD read = 0;
                if (!WinHttpReadData(hRequest, buffer.data(), available, &read)) break;
                body.append(buffer.data(), read);
                // Sanity cap: a groups list is small; refuse to buffer more
                // than 1 MB from a misbehaving endpoint.
                if (body.size() > 1024 * 1024) break;
            } while (available > 0);
            outBody = body;
            ok = true;
        }
    }
    else
    {
        WcaLog(LOGMSG_STANDARD, "FetchGroups: request failed, error %lu", GetLastError());
    }

    WinHttpCloseHandle(hRequest);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);
    return ok;
}

// The ComboBox table only exists in the compiled MSI because
// DeployConfigDlg.wxs authors one static placeholder <ListItem> under
// GroupCombo's <ComboBox> -- WiX only emits the table's schema when it's
// referenced by an authored row; INSERT INTO ComboBox against a database
// that never got the table at all fails at install time with error 2205
// ("table does not exist"), which is what a from-scratch runtime-only
// population (no static item) actually did in testing. ClearComboBoxRows
// wipes that placeholder (and anything from a previous run of this CA, if
// the user goes Back then Next again) before InsertComboBoxRow adds the
// real, server-fetched rows.
bool ClearComboBoxRows(MSIHANDLE hInstall, LPCWSTR property)
{
    PMSIHANDLE hDb = MsiGetActiveDatabase(hInstall);
    if (!hDb) return false;

    PMSIHANDLE hView;
    UINT r = MsiDatabaseOpenViewW(hDb, L"DELETE FROM `ComboBox` WHERE `Property` = ?", &hView);
    if (r != ERROR_SUCCESS) return false;

    PMSIHANDLE hRecord = MsiCreateRecord(1);
    MsiRecordSetStringW(hRecord, 1, property);

    r = MsiViewExecute(hView, hRecord);
    MsiViewClose(hView);
    return r == ERROR_SUCCESS;
}

// Inserts one row into the ComboBox table for the given property.
bool InsertComboBoxRow(MSIHANDLE hInstall, LPCWSTR property, int order, const std::wstring& text)
{
    PMSIHANDLE hDb = MsiGetActiveDatabase(hInstall);
    if (!hDb) return false;

    PMSIHANDLE hView;
    UINT r = MsiDatabaseOpenViewW(hDb,
        L"INSERT INTO `ComboBox` (`Property`, `Order`, `Value`, `Text`) VALUES (?, ?, ?, ?)",
        &hView);
    if (r != ERROR_SUCCESS) return false;

    PMSIHANDLE hRecord = MsiCreateRecord(4);
    MsiRecordSetStringW(hRecord, 1, property);
    MsiRecordSetInteger(hRecord, 2, order);
    MsiRecordSetStringW(hRecord, 3, text.c_str());
    MsiRecordSetStringW(hRecord, 4, text.c_str());

    r = MsiViewExecute(hView, hRecord);
    MsiViewClose(hView);
    return r == ERROR_SUCCESS;
}

} // namespace

UINT __stdcall FetchGroups(__in MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    DWORD er = ERROR_SUCCESS;

    hr = WcaInitialize(hInstall, "FetchGroups");
    ExitOnFailure(hr, "Failed to initialize");

    // Clear the static placeholder row unconditionally, up front, so every
    // exit path below (including the early "not configured"/"unreachable"
    // ones) leaves the combo box looking genuinely empty rather than
    // showing one blank selectable item.
    if (!ClearComboBoxRows(hInstall, L"GROUP"))
    {
        WcaLog(LOGMSG_STANDARD, "FetchGroups: failed to clear the GROUP combo box placeholder.");
    }

    {
        wchar_t apiUrl[1024] = { 0 };
        DWORD cchApiUrl = ARRAYSIZE(apiUrl);
        wchar_t deployToken[512] = { 0 };
        DWORD cchDeployToken = ARRAYSIZE(deployToken);

        MsiGetPropertyW(hInstall, L"API_URL", apiUrl, &cchApiUrl);
        MsiGetPropertyW(hInstall, L"DEPLOY_TOKEN", deployToken, &cchDeployToken);

        if (apiUrl[0] == L'\0' || deployToken[0] == L'\0')
        {
            WcaLog(LOGMSG_STANDARD, "FetchGroups: API_URL or DEPLOY_TOKEN not set, skipping.");
            goto LExit;
        }

        // Not /api/groups: that's the admin endpoint, gated by per-device
        // admin auth, and 401s for a deploy token.
        std::wstring url = std::wstring(apiUrl) + L"/api/deploy/groups";
        std::string body;
        DWORD statusCode = 0;
        if (!HttpsGetJson(url, deployToken, body, statusCode))
        {
            WcaLog(LOGMSG_STANDARD,
                "FetchGroups: could not reach the server (HTTP status %lu), falling back to free text.",
                statusCode);
            goto LExit;
        }

        std::vector<std::wstring> names = ExtractJsonStringArray(body);
        WcaLog(LOGMSG_STANDARD, "FetchGroups: got %zu group(s).", names.size());

        int order = 1;
        for (const auto& name : names)
        {
            if (!InsertComboBoxRow(hInstall, L"GROUP", order, name))
            {
                WcaLog(LOGMSG_STANDARD, "FetchGroups: failed to insert group row %d ('%ls').", order, name.c_str());
            }
            order++;
        }

        // A previous version set this via MsiSetPropertyW() *before* the
        // ComboBox insert loop above (i.e. interleaved with populating
        // GROUP's rows), using the name "GROUPS_LOADED". On a real machine
        // that produced a ComboBox showing the single literal item
        // "GROUPS_LOADED" instead of the fetched group names, even though:
        // the Control table (verified via the compiled MSI's Control table)
        // binds GroupCombo only to Property="GROUP", never to this one; the
        // JSON parsing above was verified byte-for-byte correct against the
        // real server response; and the live server response itself was
        // verified to be a clean group-name array containing no
        // "GROUPS_LOADED" string anywhere. That rules out a data or parsing
        // bug and points at the MSI engine itself reacting to a *property
        // change* fired while a ComboBox control's rows are mid-populate --
        // plausibly some dialog-refresh/notification path that ends up
        // rendering the just-changed property's name. Fixed two ways: (1)
        // this property is now named DEPLOY_GROUPS_STATUS so it can never
        // collide with GROUP by name, is never bound to any Control (grep
        // Package/UI/*.wxs -- nothing references it), and (2) it is only
        // ever set here, strictly *after* every ComboBox row for GROUP has
        // already been inserted, never interleaved with that loop. Kept
        // (rather than deleted outright) as a diagnostic property visible in
        // the MSI log/UI property dump if this ever needs revisiting.
        MsiSetPropertyW(hInstall, L"DEPLOY_GROUPS_STATUS", L"LOADED");
    }

LExit:
    er = ERROR_SUCCESS; // Never fail install setup over a reachability problem.
    return WcaFinalize(er);
}

UINT __stdcall WriteDeployJson(__in MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    DWORD er = ERROR_SUCCESS;

    LPWSTR pwzData = NULL;

    hr = WcaInitialize(hInstall, "WriteDeployJson");
    ExitOnFailure(hr, "Failed to initialize");

    hr = WcaGetProperty(L"CustomActionData", &pwzData);
    ExitOnFailure(hr, "failed to get CustomActionData");

    {
        std::wstring installFolder, deviceName, group, apiUrl, deployToken;

        // Fields are joined with this marker string by
        // WriteDeployJson.SetParam in RustDesk.wxs, not a printable
        // character like ';', since DEVICENAME/GROUP are free text typed
        // into the installer UI and could otherwise collide with the
        // delimiter. Plain ASCII: a first attempt used U+E000 (Private Use
        // Area, chosen to be XML-legal and untypeable), but that broke the
        // WiX build -- U+E000 isn't representable in the MSI database's
        // default Windows-1252 codepage.
        static const std::wstring kSep = L"##OLIDESK_SEP##";
        std::wstring all(pwzData ? pwzData : L"");
        std::vector<std::wstring> fields;
        size_t start = 0;
        while (true)
        {
            size_t pos = all.find(kSep, start);
            if (pos == std::wstring::npos)
            {
                fields.push_back(all.substr(start));
                break;
            }
            fields.push_back(all.substr(start, pos - start));
            start = pos + kSep.size();
        }

        if (fields.size() != 5)
        {
            WcaLog(LOGMSG_STANDARD, "WriteDeployJson: expected 5 fields, got %zu; aborting.", fields.size());
            goto LExit;
        }

        installFolder = fields[0];
        deviceName = fields[1];
        group = fields[2];
        apiUrl = fields[3];
        deployToken = fields[4];

        if (installFolder.empty())
        {
            WcaLog(LOGMSG_STANDARD, "WriteDeployJson: install folder is empty, aborting.");
            goto LExit;
        }
        if (apiUrl.empty() || deployToken.empty())
        {
            WcaLog(LOGMSG_STANDARD, "WriteDeployJson: API_URL or DEPLOY_TOKEN is empty, aborting.");
            goto LExit;
        }

        // "#TEMPnnnn" is Windows Installer's internal placeholder name for
        // an unresolved ComboBox item, and has leaked through into GROUP as
        // a real (bogus) value before (an empty/whitespace ListItem Text
        // rendering as this instead of blank). A separate incident put the
        // literal status string "GROUPS_LOADED" into GROUP the same way
        // (see the long comment in FetchGroups above). Whatever the exact
        // MSI-engine mechanism, never let either kind of internal artifact
        // reach the JSON or the server as a real group name -- treat it the
        // same as GROUP never having been set.
        bool looksLikePlaceholder = group.rfind(L"#TEMP", 0) == 0;
        for (const wchar_t* status : { L"GROUPS_LOADED", L"DEPLOY_GROUPS_STATUS", L"LOADED" })
        {
            if (group == status)
            {
                looksLikePlaceholder = true;
                break;
            }
        }
        if (looksLikePlaceholder)
        {
            WcaLog(LOGMSG_STANDARD,
                "WriteDeployJson: GROUP looked like an MSI placeholder/status artifact ('%ls'), treating as empty.",
                group.c_str());
            group.clear();
        }

        std::wstringstream json;
        json << L"{\n"
             << L"  \"api_url\": \"" << JsonEscape(apiUrl) << L"\",\n"
             << L"  \"deploy_token\": \"" << JsonEscape(deployToken) << L"\",\n"
             << L"  \"group\": \"" << JsonEscape(group) << L"\",\n"
             << L"  \"device_name\": \"" << JsonEscape(deviceName) << L"\"\n"
             << L"}\n";

        std::wstring path = installFolder;
        if (!path.empty() && path.back() != L'\\' && path.back() != L'/')
        {
            path += L'\\';
        }
        path += L"olidesk-deploy.json";

        std::string utf8 = WideToUtf8(json.str());

        HANDLE hFile = CreateFileW(path.c_str(), GENERIC_WRITE, 0, NULL,
            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hFile == INVALID_HANDLE_VALUE)
        {
            WcaLog(LOGMSG_STANDARD, "WriteDeployJson: failed to create '%ls', error %lu",
                path.c_str(), GetLastError());
            goto LExit;
        }

        DWORD written = 0;
        BOOL wrote = WriteFile(hFile, utf8.data(), (DWORD)utf8.size(), &written, NULL);
        CloseHandle(hFile);

        if (!wrote || written != utf8.size())
        {
            WcaLog(LOGMSG_STANDARD, "WriteDeployJson: failed to write '%ls', error %lu",
                path.c_str(), GetLastError());
            goto LExit;
        }

        WcaLog(LOGMSG_STANDARD, "WriteDeployJson: wrote '%ls'.", path.c_str());
    }

LExit:
    if (pwzData)
    {
        ReleaseStr(pwzData);
    }

    er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}
