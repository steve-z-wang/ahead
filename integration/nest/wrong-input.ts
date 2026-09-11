import type {Handler} from '../../packages/server/index.mts';
type Tx={};type Input={count:number};
const wrong:Handler<Tx,Input>=async(_context,input)=>{input.missing.toUpperCase();};
void wrong;
