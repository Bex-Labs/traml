import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.118.0';
import {createPlatformAdminHandler} from '../_shared/platform-admin.mjs';
Deno.serve(createPlatformAdminHandler({createClient,env:(name:string)=>Deno.env.get(name),kind:'actions'}));
