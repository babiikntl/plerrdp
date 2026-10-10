"use client";
import {T} from "@/app/locale-provider";

import {signIn} from "next-auth/react";
export default function Button(){return <button onClick={()=>signIn("github",{callbackUrl:"/dashboard"})}><T text={"Login GitHub · identitas saja →"}/></button>}
