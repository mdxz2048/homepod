param(
    [Parameter(Mandatory=$true)][string]$TaskFile,
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [ValidateSet('read-only','workspace-write')][string]$Sandbox = 'read-only',
    [string]$Model = 'deepseek-v4-pro-0813',
    [ValidateRange(1,7200)][int]$TimeoutSeconds = 1800,
    [ValidateRange(1,1000)][int]$MaxExecCalls = 100,
    [ValidateSet('low','medium','high')][string]$ReasoningEffort = 'high'
)
$ErrorActionPreference = 'Stop'
$bailianRoot = Join-Path $env:LOCALAPPDATA 'OpenAI/ChatGPT-Bailian'
$projectRoot = Split-Path $PSScriptRoot -Parent
$taskPath = (Resolve-Path -LiteralPath $TaskFile).Path
$resultPath = [System.IO.Path]::GetFullPath($ResultFile)
[System.IO.Directory]::CreateDirectory((Split-Path $resultPath -Parent)) | Out-Null
$savedHome = $env:CODEX_HOME
$savedKey = $env:DASHSCOPE_API_KEY
$savedEncoding = $OutputEncoding
try {
    # Use the existing user's encrypted credential; never print or copy it.
    $secure = (Get-Content -LiteralPath (Join-Path $bailianRoot 'secrets/api-key.dpapi') -Raw).Trim() | ConvertTo-SecureString
    $env:DASHSCOPE_API_KEY = [System.Net.NetworkCredential]::new('', $secure).Password
    $env:CODEX_HOME = Join-Path $bailianRoot 'codex-home'
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $logPath = $resultPath + '.log'
    python (Join-Path $PSScriptRoot 'run_bounded_worker.py') --task $taskPath --log $logPath --timeout $TimeoutSeconds --max-exec-calls $MaxExecCalls -- (Join-Path $bailianRoot 'app/resources/codex.exe') exec --ephemeral --color never -C $projectRoot -m $Model -s $Sandbox -c 'approval_policy=never' -c "model_reasoning_effort=$ReasoningEffort" -c 'tool_output_token_limit=12000' -c 'notify=[]' -c 'mcp_servers.node_repl.enabled=false' -c 'mcp_servers.cua_repl.enabled=false' -o $resultPath -
    if ($LASTEXITCODE -ne 0) { throw "DeepSeek worker exited with code $LASTEXITCODE; see $logPath" }
    Write-Output "DeepSeek task completed: $resultPath"
} finally {
    $env:CODEX_HOME = $savedHome
    $env:DASHSCOPE_API_KEY = $savedKey
    $OutputEncoding = $savedEncoding
    $secure = $null
}
