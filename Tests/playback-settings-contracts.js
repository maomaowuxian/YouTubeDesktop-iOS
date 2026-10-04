const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const source = fs.readFileSync(path.join(__dirname, '../YouTubePoC/ViewController.swift'), 'utf8');
new vm.Script(source.split('let pageTweaks = #"""')[1].split('"""#')[0]);
const helper = source.slice(source.indexOf("          // YouTube's HLS muxed variants"), source.indexOf("          window.__rayNativePiPOwner = '';"));
const handoff = source.slice(source.indexOf('          window.__rayPauseForNativePiP ='), source.indexOf('          const adSkipSelectors ='));
const id = 'TESTVIDEO01';
let ad = false, cc = true, selected = {vssId: '.en', languageCode: 'en'};
let response = {videoDetails: {videoId:id}, streamingData: {adaptiveFormats:[]},
  captions:{playerCaptionsTracklistRenderer:{captionTracks:[
    {vssId:'.en',languageCode:'en',name:{simpleText:'English'},baseUrl:'https://www.youtube.com/api/timedtext?v=TESTVIDEO01'},
    {vssId:'.zh',languageCode:'zh',name:{runs:[{text:'中文'}]},baseUrl:'https://www.youtube.com/api/timedtext?v=TESTVIDEO01&lang=zh'}]}}};
let optionCalls = [], rateCalls = [], fetchCalls = 0, resolveBody = null;
const video = {currentSrc:'https://r1.googlevideo.com/api/manifest/hls_playlist/test', currentTime:42,
  duration:120,playbackRate:1.5,paused:false,ended:false,isConnected:true,
  pause(){this.paused=true;}, play(){this.paused=false;return Promise.resolve();}};
const player = {getAudioTrack:()=>({id:'und',xtags:''}), getPlayerResponse:()=>response,
  getOption:()=>selected,setOption:(...args)=>optionCalls.push(args),loadModule:null,
  setPlaybackRate:rate=>rateCalls.push(rate)};
const sandbox = {URL,AbortController,setTimeout,clearTimeout,
  location:{href:'https://www.youtube.com/watch?v='+id},window:{__rayResetPiPButton:()=>{}},
  navigator:{mediaSession:{metadata:{title:'test'},playbackState:'playing'}},
  document:{getElementById:()=>player,querySelector:s=>s==='.html5-video-player video'?video:
    s==='.html5-video-player'?{classList:{contains:()=>ad}}:s==='.ytp-subtitles-button'?{getAttribute:()=>String(cc)}:null},
  post:()=>{},fetch:async()=>{fetchCalls++;return {ok:true,text:()=>new Promise(resolve=>{resolveBody=resolve;})};}};
vm.createContext(sandbox);
vm.runInContext(helper+handoff+'\nthis.read=readAudioTrack;this.captions=readCaptionSettings;this.parse=parseCaptionBody;this.remember=rememberCaptionResponse;this.cache=captionCuesCache;this.webSettings=readWebPlaybackSettings;this.webApply=applyWebPlaybackSetting;',sandbox);
const take = () => sandbox.window.__rayPauseForNativePiP(id,video.currentSrc,sandbox.read().key);
const restore = (play,rate,captions=null) => sandbox.window.__rayRestoreAfterNativePiP(id,60,play,rate,captions);
(async () => {
  for (const rate of [0.5,0.75,1.25,1.5,2,3]) {
    video.paused=false;video.playbackRate=rate;sandbox.window.__rayNativePiPOwner='';
    const snap=take();assert.equal(snap.playbackRate,rate);assert.equal(snap.captions.enabled,true);
    assert.equal(snap.captions.selectedID,'.en');assert.ok(!JSON.stringify(snap).includes('timedtext'),'No signed URL in snapshot');
    assert.equal(restore(false,rate),true);assert.equal(video.playbackRate,rate);assert.equal(video.paused,true);
  }
  video.paused=false;video.playbackRate=1.5;take();
  assert.equal(sandbox.window.__raySetNativePlaybackRate(id,2),true);assert.equal(video.playbackRate,2);assert.equal(video.paused,true);
  restore(true,2,'.zh');assert.equal(video.paused,false);assert.equal(video.playbackRate,2);
  assert.equal(optionCalls.at(-1)[2].vssId,'.zh');
  take();restore(false,0.75,'');assert.deepEqual(Object.keys(optionCalls.at(-1)[2]),[]);
  take();const oldRate=video.playbackRate;
  assert.equal(sandbox.window.__raySetNativePlaybackRate(id,NaN),false);assert.equal(video.playbackRate,oldRate);
  sandbox.location.href='https://www.youtube.com/watch?v=TESTVIDEO02';
  assert.equal(restore(true,2),false);assert.equal(video.paused,true,'Old video cannot resume after navigation');
  sandbox.location.href='https://www.youtube.com/watch?v='+id;video.paused=false;take();
  const json=JSON.stringify({events:[{tStartMs:1000,dDurationMs:2000,segs:[{utf8:'hello '},{utf8:'world'}]},
    {tStartMs:-1,dDurationMs:0,segs:[{utf8:'bad'}]},{tStartMs:4000,dDurationMs:1000,segs:[]}]});
  assert.equal(sandbox.parse(json).length,1);assert.equal(sandbox.parse(json)[0].text,'hello world');
  const pending=sandbox.window.__rayLoadNativeCaptions(id,'.en');
  await new Promise(setImmediate);assert.equal(fetchCalls,1);assert.equal(typeof resolveBody,'function');resolveBody(json);
  const payload=await pending;assert.equal(payload.cues.length,1);
  response.captions.playerCaptionsTracklistRenderer.captionTracks[0].baseUrl='https://evil.example/api/timedtext';
  const before=fetchCalls;assert.equal(await sandbox.window.__rayLoadNativeCaptions(id,'.en'),null);assert.equal(fetchCalls,before);
  response.captions.playerCaptionsTracklistRenderer.captionTracks[0].baseUrl='https://www.youtube.com/api/timedtext?v='+id;
  const stale=sandbox.window.__rayLoadNativeCaptions(id,'.en');
  await new Promise(setImmediate);sandbox.window.__rayNativePiPOwner='TESTVIDEO02';resolveBody(json);
  assert.equal(await stale,null,'Captions fetched for an old owner are discarded');
  sandbox.window.__rayNativePiPOwner=id;
  sandbox.remember('https://www.youtube.com/api/timedtext?v='+id+'&lang=en',json,id);
  assert.equal(sandbox.cache.size,1);
  const cached=await sandbox.window.__rayLoadNativeCaptions(id,'.en');
  assert.equal(cached.cues[0].text,'hello world');
  assert.equal(fetchCalls,before+1,'Cached normal player response needs no new request');
  for (const url of [
    'https://evil.example/api/timedtext?v='+id+'&lang=zh',
    'https://www.youtube.com/api/timedtext?v=TESTVIDEO02&lang=zh',
    'https://www.youtube.com/api/timedtext?v='+id+'&lang=zh&tlang=en',
    'https://www.youtube.com/api/timedtext?v='+id+'&lang=zh&kind=asr']) {
    sandbox.remember(url,json,id);
    assert.equal(sandbox.cache.size,1,'Unrelated, translated and mismatched tracks cannot enter cache');
  }
  sandbox.remember('https://www.youtube.com/api/timedtext?v='+id+'&lang=zh',json,'TESTVIDEO02');
  assert.equal(sandbox.cache.size,1,'Stale request cannot populate a current track');
  response.videoDetails.videoId='TESTVIDEO02';assert.equal(sandbox.captions(id).tracks.length,0);
  response.videoDetails.videoId=id;
  response.captions={playerCaptionsTracklistRenderer:{captionTracks:[]}};
  sandbox.window.__rayNativePiPOwner='';
  assert.equal(sandbox.webSettings().captions.tracks.length,0);
  assert.equal(sandbox.webApply(id,1.5),true,'No captions must not disable speed settings');
  assert.equal(video.playbackRate,1.5);
  video.paused=true;
  assert.equal(sandbox.webApply(id,0.75),true);assert.equal(video.paused,true);
  assert.equal(sandbox.webApply(id,null,'.missing'),false);
  assert.equal(sandbox.webApply('TESTVIDEO02',2),false);
  sandbox.window.__rayNativePiPOwner=id;
  assert.equal(sandbox.webSettings(),null);
  assert.equal(sandbox.webApply(id,2),false,'Web settings cannot change a native owner');
  console.log('PASS: playback rate round trips, paused settings, caption selection/parser and stale fetch contracts');
})().catch(error=>{console.error(error);process.exit(1);});
