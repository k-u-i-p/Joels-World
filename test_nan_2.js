// Read the code from tennis.js, append `export { serveBall };` to the end temporarily, evaluate the scope natively, and dump the objects producing the bug!
import fs from 'fs';

const fileLines = fs.readFileSync('src/tennis.js', 'utf8').split('\n');
fileLines.push('export { getLimbs, serveBall, update, getPlayerY, getNpcY, calculateAimAngles, determineOptimalInterceptPoint };');
fs.writeFileSync('src/tennis_debug.js', fileLines.join('\n'), 'utf8');
