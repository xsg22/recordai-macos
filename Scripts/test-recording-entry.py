from pathlib import Path
import subprocess
sources=[str(p) for p in Path('Sources').glob('*.swift') if p.name!='CoHearTranscribeApp.swift']
app=Path('Sources/CoHearTranscribeApp.swift').read_text().replace('@main\n','')
Path('.build/TestAppTypes.swift').write_text(app)
tests=['AgentDataSmoke','LibrarySmoke','AppStateSmoke','SpeakerEditingSmoke','MeetingWorkspacePersistenceSmoke','QuitFlowSmoke','RecorderSmoke','CapturePolishSmoke','ParagraphPlaybackSmoke','RecordingProfileSmoke','MiniRecordingSmoke','ContinuousRecordingSmoke','LiveAudioSmoke','ASRModelDownloadSmoke']
texts=[]
for test in tests:
    texts.append(Path('Tests/'+test+'.swift').read_text().replace('@main',''))
texts.append('@main struct RegressionMain { @MainActor static func main() async throws { '+ '; '.join(('try await ' if t in ['QuitFlowSmoke','RecorderSmoke','CapturePolishSmoke','ParagraphPlaybackSmoke','MiniRecordingSmoke','ContinuousRecordingSmoke','ASRModelDownloadSmoke'] else 'try ')+t+'.main()' for t in tests)+' } }')
Path('.build/RecordingEntryRegression.swift').write_text('\n'.join(texts))
subprocess.run(['xcrun','swiftc','-warnings-as-errors','-swift-version','5','-parse-as-library','-target','arm64-apple-macosx14.0',*sources,'.build/TestAppTypes.swift','.build/RecordingEntryRegression.swift','-o','.build/recording-entry-regression'],check=True)
subprocess.run(['.build/recording-entry-regression'],check=True)
