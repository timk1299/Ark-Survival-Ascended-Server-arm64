#define UNICODE
#define _UNICODE
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

static void print_error(const wchar_t *operation) {
  fwprintf(stderr, L"%ls failed with Windows error %lu\n", operation, GetLastError());
}

int wmain(int argc, wchar_t **argv) {
  URL_COMPONENTS parts = {0};
  HINTERNET session = NULL;
  HINTERNET connection = NULL;
  HINTERNET request = NULL;
  wchar_t host[256] = {0};
  wchar_t path[2048] = {0};
  DWORD status = 0;
  DWORD status_size = sizeof(status);
  int result = 1;

  if (argc != 2) {
    fwprintf(stderr, L"usage: pok_https_probe.exe https://host/path\n");
    return 2;
  }

  parts.dwStructSize = sizeof(parts);
  parts.lpszHostName = host;
  parts.dwHostNameLength = ARRAYSIZE(host);
  parts.lpszUrlPath = path;
  parts.dwUrlPathLength = ARRAYSIZE(path);
  if (!WinHttpCrackUrl(argv[1], 0, 0, &parts) || parts.nScheme != INTERNET_SCHEME_HTTPS) {
    print_error(L"WinHttpCrackUrl (HTTPS URL required)");
    goto cleanup;
  }

  session = WinHttpOpen(L"POK-manager Proton HTTPS probe/1.0",
                        WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (!session) { print_error(L"WinHttpOpen"); goto cleanup; }
  WinHttpSetTimeouts(session, 10000, 10000, 10000, 20000);

  connection = WinHttpConnect(session, host, parts.nPort, 0);
  if (!connection) { print_error(L"WinHttpConnect"); goto cleanup; }
  request = WinHttpOpenRequest(connection, L"GET", path[0] ? path : L"/", NULL,
                               WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                               WINHTTP_FLAG_SECURE);
  if (!request) { print_error(L"WinHttpOpenRequest"); goto cleanup; }
  if (!WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                          WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
    print_error(L"WinHttpSendRequest"); goto cleanup;
  }
  if (!WinHttpReceiveResponse(request, NULL)) {
    print_error(L"WinHttpReceiveResponse"); goto cleanup;
  }
  if (!WinHttpQueryHeaders(request,
                           WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                           WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size,
                           WINHTTP_NO_HEADER_INDEX)) {
    print_error(L"WinHttpQueryHeaders"); goto cleanup;
  }

  wprintf(L"HTTPS probe received HTTP %lu\n", status);
  result = status >= 200 && status < 500 ? 0 : 1;

cleanup:
  if (request) WinHttpCloseHandle(request);
  if (connection) WinHttpCloseHandle(connection);
  if (session) WinHttpCloseHandle(session);
  return result;
}
