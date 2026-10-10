const fs=require('fs'),vm=require('vm'),assert=require('assert');
const nodes=new Map(),messages=[];
function node(key){if(!nodes.has(key))nodes.set(key,{style:{},innerHTML:'',textContent:''});return nodes.get(key);}
const context=vm.createContext({window:{innerWidth:820,innerHeight:620,addEventListener(){},webkit:{messageHandlers:{rapoo:{postMessage:m=>messages.push(m)}}}},document:{getElementById:node,querySelector:node},console});
const html=fs.readFileSync(__dirname+'/../Resources/index.html','utf8');
vm.runInContext(html.split('<script>')[1].split('</script>')[0],context);
assert(messages.some(m=>m.command==='ready'));
assert(messages.find(m=>m.command==='micSettings').monitor===false);
vm.runInContext("page='Mic';render();setMicStatus({active:true,hardwareGain:true,hardwareLevel:.7});toggleMic('monitor');",context);
assert(messages.at(-1).command==='micSettings'&&messages.at(-1).monitor===true);
assert(!node('panel').innerHTML.includes('Record WAV'));
assert(!/id="hardwareGain"[^>]*disabled/.test(node('panel').innerHTML));
vm.runInContext("toggleMic('monitor');",context);
assert(messages.at(-1).monitor===false);
vm.runInContext("setMicStatus({active:false,monitor:false});toggleMic('monitor');",context);
assert(node('status').textContent.includes('Start Mic'));
console.log('PASS: startup bridge, monitor on/off, stopped-mic guard, recording removal and input-level refresh.');
