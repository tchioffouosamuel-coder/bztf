# Régénère android/app/src/main/res/raw/gate_alarm.wav : message vocal
# français (voix Windows « Hortense ») sur fond de sirène douce.
# Prérequis : Windows avec la voix fr-FR, Python 3 et numpy.
#   powershell -ExecutionPolicy Bypass -File tool\gate_alarm\generate.ps1
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$voice = Join-Path $env:TEMP 'gate_voice.wav'
$target = Join-Path $root 'android\app\src\main\res\raw\gate_alarm.wav'

Add-Type -AssemblyName System.Speech
$speech = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speech.SelectVoice('Microsoft Hortense Desktop')
$speech.Rate = -1
$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(22050, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$speech.SetOutputToWaveFile($voice, $format)
$prompt = New-Object System.Speech.Synthesis.PromptBuilder([System.Globalization.CultureInfo]::GetCultureInfo('fr-FR'))
$prompt.AppendText('Attention !')
$prompt.AppendBreak([TimeSpan]::FromMilliseconds(350))
$prompt.AppendText('Ne sortez pas avec un livre non emprunté.')
$prompt.AppendBreak([TimeSpan]::FromMilliseconds(300))
$prompt.AppendText("Redirigez-vous vers le poste d'emprunt.")
$prompt.AppendBreak([TimeSpan]::FromMilliseconds(300))
$prompt.AppendText("Si vous avez des difficultés, allez au poste d'emprunt assisté.")
$speech.Speak($prompt)
$speech.Dispose()

python (Join-Path $PSScriptRoot 'mix_alarm.py') $voice $target
Remove-Item $voice
