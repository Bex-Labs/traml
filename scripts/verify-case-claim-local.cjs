'use strict';
try {require('./case-claim-local-tools.cjs').run(false);} catch(error) {console.error('Local claim verification failed:',error.message);process.exitCode=1;}
