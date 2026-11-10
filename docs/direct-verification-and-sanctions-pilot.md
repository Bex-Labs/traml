# Direct identity verification and sanctions pilot

CoreAML can fetch public sanctions designations and compare names locally. Production identity verification needs an approved NIMC or NIBSS connection for the relevant bank and use case.

## Try the sanctions pilot

From the CoreAML root in PowerShell, with Python 3.10 or later:

```powershell
$snapshot = Join-Path $env:TEMP "coreaml-sanctions-pilot.json"
python .\scripts\coreaml-sanctions-pilot.py refresh $snapshot
if ($LASTEXITCODE -ne 0) { throw "Official feed refresh failed." }
python .\scripts\coreaml-sanctions-pilot.py screen $snapshot
```

Enter a fictional name for a negative test or copy a published designation's name from one of the sources for a positive test. Only the refresh command accesses the network. The comparison runs against the snapshot on your machine. The refresh replaces the previous snapshot only after all sources parse successfully.

The pilot covers UN consolidated records, OFAC SDN and non-SDN records, and the individual and entity names in Nigeria's public designation tables. It includes UN and OFAC aliases from the downloaded feeds. The Nigeria parser uses the names on the index page and links each hit to its official detail record. It does not fetch Nigeria detail pages for aliases or other identifiers. The snapshot records each input's SHA-256 and the retrieval time.

A possible hit needs disambiguation against identifiers on the source record. A no-match result means the name did not match in that snapshot. The pilot compares normalized names and, for individuals, reordered name tokens. It does not cover spelling variants, transliteration, PEPs or adverse media. It does not create alerts, change KYC status or touch the database.

Before connecting it to an onboarding workflow, define which lists each bank applies, freshness requirements, how reviewers confirm or dismiss matches, and how prior decisions are preserved when sources update. Keep sanctions records out of the legacy transaction narration substring rule until the bank has tested false-positive volume in shadow mode.

Official sources:

- [UN Security Council consolidated list](https://main.un.org/securitycouncil/en/content/un-sc-consolidated-list)
- [OFAC Sanctions List Service](https://ofac.treasury.gov/sanctions-list-service)
- [Nigeria Sanctions Committee designations](https://nigsac.gov.ng/IndSancList)
- [FATF guidance on politically exposed persons](https://www.fatf-gafi.org/en/publications/Fatfrecommendations/Peps-r12-r22.html)

## Apply for direct identity access

### NIMC

Review the [NINAuth developer guidance](https://ninauth.nimc.gov.ng/developers) and open the [Verification Partner page](https://ninauth.nimc.gov.ng/verification-partner). If a bank will own the credentials, ask the bank's compliance and technology teams to identify the right enterprise onboarding route. Confirm that the approved arrangement allows CoreAML to act as the technical processor before collecting customer information.

Suggested inquiry:

> We are developing CoreAML, a KYC onboarding and AML platform for financial institutions in Nigeria. We want to use NINAuth for consent-based identity verification. Can a software vendor onboard as a Verification Partner, or should each bank onboard as an enterprise and authorise CoreAML to integrate on its behalf? Please share the required organisation documents, approval steps, test environment and synthetic test identities, available verification scopes, and any restrictions on storage or reuse of returned attributes.

### NIBSS

Use the [NIBSS contact page](https://nibss-plc.com.ng/contact/) or the bank's existing NIBSS relationship manager. The [BVN product page](https://nibss-plc.com.ng/bank-verification-numberbvn/) describes verification services. Request the applicable institutional onboarding and technical materials.

Suggested inquiry:

> We are developing CoreAML for financial institutions and would like to integrate BVN verification in a bank's KYC onboarding flow. Is a software vendor eligible for direct API access, or must the licensed bank hold the agreement and authorise us as its technical processor? Please share the applicable access requirements, UAT endpoints and fixtures, authentication and network controls, match-only options, permitted response fields, and production onboarding steps.

## Connect approved providers to CoreAML

Once UAT access is issued, add one server-side adapter per authority. Derive the bank from the authenticated staff session and route requests through that bank's approved configuration. Keep credentials in server secrets. Store the provider, environment, time, request reference and match outcome. Keep raw identifiers and full provider responses out of application logs. Test success, mismatch, expired consent where applicable, provider outage and cross-bank access denial before enabling any production route.

For PEP coverage, validate the bank's requirements separately. Public officeholder lists can supplement screening, and a bank can connect a licensed data feed where broader coverage is needed. CoreAML owns candidate review and the bank's final decision.
