// DeployConfig.cpp — the two custom actions behind the deployment
// device-registration prompt (Package/UI/DeployConfigDlg.wxs):
//
//  - FetchGroups: immediate CA, runs when "Next" is clicked on
//    MyInstallDirDlg (before DeployConfigDlg is shown). GETs
//    {API_URL}/api/groups with the baked-in deploy token and populates the
//    GROUP combo box's ComboBox table rows at runtime. Never blocks or
//    fails the install: on any error (unreachable server, timeout, bad
//    response) it just logs and leaves the combo box empty, which is still
//    a usable free-text field since it isn't list-restricted.
//
//  - WriteDeployJson: deferred CA, runs after InstallFiles. Writes
//    olidesk-deploy.json into the install folder from DEVICENAME, GROUP,
//    and the baked-in API_URL/DEPLOY_TOKEN, so the app can self-register on
//    first launch (flutter/lib/common/olidesk_deploy.dart) instead of
//    needing that file dropped in by hand after install.
//
// Both are compiled in only when the installer was built with
// --api-url/--deploy-token (see ../preprocess.py and the `<?ifdef ApiUrl?>`
// guards throughout the Package/*.wxs files) -- i.e. the client build, not
// the admin build.

#include "pch.h"
#include <winhttp.h>
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

void SkipWhitespace(const std::string& s, size_t& i)
{
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++;
}

// Extracts the "name" value of every JSON object at brace-depth 1 inside
// the root array returned by GET /api/groups -- i.e. top-level groups
// only, deliberately ignoring nested "children". The register endpoint
// (see olidesk-api/app.py's _get_or_create_top_level_group) only ever
// resolves a group name against top-level groups, so listing subgroups
// here would just be misleading.
std::vector<std::wstring> ExtractTopLevelGroupNames(const std::string& json)
{
    std::vector<std::wstring> names;
    size_t i = 0;
    int braceDepth = 0;

    while (i < json.size())
    {
        char c = json[i];
        if (c == '"')
        {
            std::string value;
            if (!ParseJsonStringLiteral(json, i, value))
            {
                break; // malformed; keep whatever we already found
            }
            if (value == "name" && braceDepth == 1)
            {
                SkipWhitespace(json, i);
                if (i < json.size() && json[i] == ':')
                {
                    i++;
                    SkipWhitespace(json, i);
                    std::string nameValue;
                    if (ParseJsonStringLiteral(json, i, nameValue))
                    {
                        names.push_back(Utf8ToWide(nameValue));
                    }
                }
            }
            continue;
        }
        if (c == '{') braceDepth++;
        else if (c == '}') braceDepth--;
        i++;
    }
    return names;
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
// else (unreachable, timeout, TLS failure, non-200, ...). Bounded
// timeouts so a dead or slow server can never hang the installer --
// "install never blocks" is the whole point of the fallback requirement.
bool HttpsGetJson(const std::wstring& url, const std::wstring& bearerToken, std::string& outBody)
{
    bool ok = false;

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
        else
        {
            WcaLog(LOGMSG_STANDARD, "FetchGroups: HTTP status %lu", statusCode);
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

// Inserts one row into the ComboBox table for the given property. The
// table itself is created by the WiX compiler because DeployConfigDlg.wxs
// declares a Control of Type="ComboBox" -- no static <ComboBox> items are
// needed there since every row is inserted here, at runtime.
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

        std::wstring url = std::wstring(apiUrl) + L"/api/groups";
        std::string body;
        if (!HttpsGetJson(url, deployToken, body))
        {
            WcaLog(LOGMSG_STANDARD, "FetchGroups: could not reach the server, falling back to free text.");
            goto LExit;
        }

        // Reached the server successfully -- suppress the "couldn't reach
        // the server" hint even if it happens to have zero groups so far.
        MsiSetPropertyW(hInstall, L"GROUPS_LOADED", L"1");

        std::vector<std::wstring> names = ExtractTopLevelGroupNames(body);
        WcaLog(LOGMSG_STANDARD, "FetchGroups: got %zu group(s).", names.size());

        int order = 1;
        for (const auto& name : names)
        {
            InsertComboBoxRow(hInstall, L"GROUP", order++, name);
        }
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

        // Fields are joined with U+E000 (Private Use Area) by
        // WriteDeployJson.SetParam in RustDesk.wxs, not a printable
        // character like ';', since DEVICENAME/GROUP are free text typed
        // into the installer UI and could otherwise collide with the
        // delimiter.
        std::wstring all(pwzData ? pwzData : L"");
        std::vector<std::wstring> fields;
        size_t start = 0;
        for (size_t i = 0; i <= all.size(); i++)
        {
            if (i == all.size() || all[i] == (wchar_t)0xE000)
            {
                fields.push_back(all.substr(start, i - start));
                start = i + 1;
            }
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
