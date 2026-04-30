# POC: Client-style work items matching real eCommerce board patterns
# No real names used. Assignee = urvashi.upadhyay@yash.com
$adoPat = $env:ADO_PAT
if (-not $adoPat) { Write-Host "Set env:ADO_PAT first"; exit 1 }
$org="YashTech-DevOps"; $proj="YASH-DevOps-Serverless"; $area="YASH-DevOps-Serverless\POC-Migration"
$b64=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
$hdr=@{Authorization="Basic $b64";"Content-Type"="application/json-patch+json"}
$base="https://dev.azure.com/$org/$proj/_apis/wit/workitems"

function CW($type,$title,$state="New",$parent=0,$fields=@{},$desc="") {
  $body=@(@{op='add';path='/fields/System.Title';value=$title},
          @{op='add';path='/fields/System.State';value=$state},
          @{op='add';path='/fields/System.AreaPath';value=$area})
  if($desc){$body+=@{op='add';path='/fields/System.Description';value=$desc}}
  foreach($k in $fields.Keys){$body+=@{op='add';path="/fields/$k";value=$fields[$k]}}
  if($parent -gt 0){$body+=@{op='add';path='/relations/-';value=@{rel='System.LinkTypes.Hierarchy-Reverse';url="https://dev.azure.com/$org/$proj/_apis/wit/workItems/$parent"}}}
  $u="$base/`$$([uri]::EscapeDataString($type))?api-version=7.1"
  try{$r=Invoke-RestMethod -Method PATCH -Uri $u -Headers $hdr -Body (ConvertTo-Json @($body) -Depth 10);Write-Host "OK [$type] #$($r.id) $title";return $r.id}
  catch{Write-Host "FAIL [$type] $title - $($_.Exception.Message)";return 0}
}
function UPD($id,$fields){
  $body=@();foreach($k in $fields.Keys){$body+=@{op='add';path="/fields/$k";value=$fields[$k]}}
  try{Invoke-RestMethod -Method PATCH -Uri "$base/$($id)?api-version=7.1" -Headers $hdr -Body (ConvertTo-Json @($body) -Depth 5)|Out-Null;Write-Host "  Updated #$id"}
  catch{Write-Host "  Update FAIL #$id"}
}
function AddComment($id,$text){
  $ch=@{Authorization="Basic $b64";"Content-Type"="application/json"}
  try{Invoke-RestMethod -Method POST -Uri "https://dev.azure.com/$org/$proj/_apis/wit/workitems/$id/comments?api-version=7.1-preview.4" -Headers $ch -Body (@{text=$text}|ConvertTo-Json)|Out-Null;Write-Host "  Comment on #$id"}
  catch{Write-Host "  Comment FAIL #$id"}
}
function AddLink($src,$tgt,$rel="System.LinkTypes.Related"){
  $body=@(@{op='add';path='/relations/-';value=@{rel=$rel;url="https://dev.azure.com/$org/$proj/_apis/wit/workItems/$tgt"}})
  try{Invoke-RestMethod -Method PATCH -Uri "$base/$($src)?api-version=7.1" -Headers $hdr -Body (ConvertTo-Json @($body) -Depth 5)|Out-Null;Write-Host "  Linked #$src->#$tgt"}
  catch{Write-Host "  Link FAIL"}
}

Write-Host "`n=== Creating Client-Style POC Items ===" -ForegroundColor Cyan

# --- EPICS (4) ---
$e1=CW 'Epic' 'Infor ERP Integration' 'New' 0 @{"Microsoft.VSTS.Common.Priority"=1;"System.Tags"="erp;integration;platform";"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"} "<p>Full integration with Infor ERP for order processing, inventory sync, and customer data.</p>"
$e2=CW 'Epic' 'Open Product Catalog For Unauthenticated Users' 'New' 0 @{"Microsoft.VSTS.Common.Priority"=2;"System.Tags"="catalog;guest;browsing";"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"}
$e3=CW 'Epic' 'Cart Page Pilot Ecom 2.0' 'New' 0 @{"Microsoft.VSTS.Common.Priority"=1;"System.Tags"="cart;ecom2;pilot";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"}
$e4=CW 'Epic' 'Customer Category Management' 'New' 0 @{"Microsoft.VSTS.Common.Priority"=2;"System.Tags"="category;admin;taxonomy";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"}
# Update epic states
if($e2){UPD $e2 @{"System.State"="Active"}}
if($e3){UPD $e3 @{"System.State"="Active"}}
if($e4){UPD $e4 @{"System.State"="Closed"}}

# --- FEATURES (6) ---
$f1=CW 'Feature' 'Item Cap (Max Quantity) Driven Order Validation' 'New' $e1 @{"Microsoft.VSTS.Common.Priority"=2;"Microsoft.VSTS.Scheduling.StoryPoints"=8;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="validation;ordering";"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"}
$f2=CW 'Feature' 'Rules Based Order Approval Process' 'New' $e1 @{"Microsoft.VSTS.Common.Priority"=1;"Microsoft.VSTS.Scheduling.StoryPoints"=13;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="approval;workflow";"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"}
$f3=CW 'Feature' 'Document Sharing' 'New' $e2 @{"Microsoft.VSTS.Common.Priority"=3;"Microsoft.VSTS.Scheduling.StoryPoints"=5;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="documents;sharing";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"}
$f4=CW 'Feature' 'Web Accessibility 2.0 AA Standards' 'New' $e2 @{"Microsoft.VSTS.Common.Priority"=1;"Microsoft.VSTS.Scheduling.StoryPoints"=13;"Microsoft.VSTS.Common.ValueArea"="Architectural";"System.Tags"="accessibility;wcag";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$f5=CW 'Feature' 'Punchout Integration' 'New' $e3 @{"Microsoft.VSTS.Common.Priority"=2;"Microsoft.VSTS.Scheduling.StoryPoints"=8;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="punchout;integration";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$f6=CW 'Feature' 'Export Feature for Inventory Management Page' 'New' $e1 @{"Microsoft.VSTS.Common.Priority"=2;"Microsoft.VSTS.Scheduling.StoryPoints"=5;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="export;inventory"}
if($f1){UPD $f1 @{"System.State"="Active"}}
if($f2){UPD $f2 @{"System.State"="Resolved"}}
if($f4){UPD $f4 @{"System.State"="Active"}}
if($f5){UPD $f5 @{"System.State"="Closed"}}

# --- PRODUCT BACKLOG ITEMS (8) ---
$p1=CW 'Product Backlog Item' 'All Products: Faceted Search - Show Stock/Non Stock' 'New' $f1 @{"Microsoft.VSTS.Common.Priority"=1;"Microsoft.VSTS.Scheduling.StoryPoints"=5;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="search;filter;stock;PIM";"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"} "<p>As a buyer, I want to filter products by stock availability so I only see items that can ship immediately.</p><h3>Acceptance Criteria</h3><ul><li>Filter shows In Stock / Out of Stock options</li><li>Results update in under 2 seconds</li><li>Filter count badges show accurate numbers</li></ul>"
$p2=CW 'Product Backlog Item' 'Catalog Sorting' 'New' $f1 @{"Microsoft.VSTS.Common.Priority"=2;"Microsoft.VSTS.Scheduling.StoryPoints"=3;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="catalog;sorting;UX";"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"}
$p3=CW 'Product Backlog Item' 'Provide a PO number with my order' 'New' $f2 @{"Microsoft.VSTS.Common.Priority"=1;"Microsoft.VSTS.Scheduling.StoryPoints"=5;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="checkout;PO;ERP";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"} "<p>As a buyer, I want to enter a PO number during checkout so my company can track orders against purchase orders in the ERP system.</p>"
$p4=CW 'Product Backlog Item' 'Sticky layout on checkout page' 'New' $f2 @{"Microsoft.VSTS.Common.Priority"=3;"Microsoft.VSTS.Scheduling.StoryPoints"=2;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="checkout;UX;layout";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"}
$p5=CW 'Product Backlog Item' 'Create customer categories with name and assigned products' 'New' $f3 @{"Microsoft.VSTS.Common.Priority"=2;"Microsoft.VSTS.Scheduling.StoryPoints"=5;"Microsoft.VSTS.Common.ValueArea"="Architectural";"System.Tags"="category;admin;taxonomy";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$p6=CW 'Product Backlog Item' 'Delete a customer specific category' 'New' $f3 @{"Microsoft.VSTS.Common.Priority"=3;"Microsoft.VSTS.Scheduling.StoryPoints"=2;"Microsoft.VSTS.Common.ValueArea"="Architectural";"System.Tags"="category;delete;admin";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$p7=CW 'Product Backlog Item' 'Skip over stop words when performing search' 'New' $f4 @{"Microsoft.VSTS.Common.Priority"=2;"Microsoft.VSTS.Scheduling.StoryPoints"=3;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="search;NLP;stopwords";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S3"}
$p8=CW 'Product Backlog Item' 'Insite Analytics Business Unit Differentiation' 'New' $e4 @{"Microsoft.VSTS.Common.Priority"=2;"Microsoft.VSTS.Scheduling.StoryPoints"=8;"Microsoft.VSTS.Common.ValueArea"="Business";"System.Tags"="analytics;reporting";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S3"}
# PBI states
if($p1){UPD $p1 @{"System.State"="Active"}}
if($p2){UPD $p2 @{"System.State"="Active"}}
if($p3){UPD $p3 @{"System.State"="Resolved"}}
if($p4){UPD $p4 @{"System.State"="Closed"}}
if($p6){UPD $p6 @{"System.State"="Closed"}}

# --- CHANGE REQUEST (2) ---
$cr1=CW 'Change Request' 'Performance: Sign in Page' 'New' $f4 @{"Microsoft.VSTS.Common.Priority"=1;"System.Tags"="performance;signin;critical";"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"} "<p>Sign-in page takes over 8 seconds to load. Target: under 2 seconds. Requires CDN optimization and lazy loading.</p>"
$cr2=CW 'Change Request' 'CDN Assets Should Not Be Publicly Accessible' 'New' $f4 @{"Microsoft.VSTS.Common.Priority"=1;"System.Tags"="security;CDN;compliance";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
if($cr1){UPD $cr1 @{"System.State"="Active"}}
if($cr2){UPD $cr2 @{"System.State"="Closed"}}

# --- TASKS (14) ---
$t1=CW 'Task' 'On left pane add option to show if inventory is in Stock or not' 'New' $p1 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=8;"Microsoft.VSTS.Scheduling.RemainingWork"=5;"Microsoft.VSTS.Scheduling.CompletedWork"=3;"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"}
$t2=CW 'Task' 'Sort by recently purchased' 'New' $p2 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=6;"Microsoft.VSTS.Scheduling.RemainingWork"=6;"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"}
$t3=CW 'Task' 'Create UI for adding products' 'New' $p5 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=8;"Microsoft.VSTS.Scheduling.RemainingWork"=4;"Microsoft.VSTS.Scheduling.CompletedWork"=4;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$t4=CW 'Task' 'Create API for getting customer categories' 'New' $p5 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=6;"Microsoft.VSTS.Scheduling.CompletedWork"=6;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$t5=CW 'Task' 'Create UI for viewing the category hierarchy' 'New' $p5 @{"Microsoft.VSTS.Common.Activity"="Design";"Microsoft.VSTS.Scheduling.OriginalEstimate"=4;"Microsoft.VSTS.Scheduling.RemainingWork"=4;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$t6=CW 'Task' 'Update data model for category hierarchy' 'New' $p5 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=4;"Microsoft.VSTS.Scheduling.CompletedWork"=4;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"}
$t7=CW 'Task' 'Create API for adding sub-category to customer category' 'New' $p5 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=6;"Microsoft.VSTS.Scheduling.CompletedWork"=6;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"}
$t8=CW 'Task' 'Display Manufacturer Name on PLP' 'New' $p2 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=4;"Microsoft.VSTS.Scheduling.RemainingWork"=2;"Microsoft.VSTS.Scheduling.CompletedWork"=2;"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"}
$t9=CW 'Task' 'User Login Takes too long' 'New' $cr1 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=16;"Microsoft.VSTS.Scheduling.RemainingWork"=8;"Microsoft.VSTS.Scheduling.CompletedWork"=8;"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"}
$t10=CW 'Task' 'Edit Custom Category UI' 'New' $p6 @{"Microsoft.VSTS.Common.Activity"="Design";"Microsoft.VSTS.Scheduling.OriginalEstimate"=6;"Microsoft.VSTS.Scheduling.CompletedWork"=6;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$t11=CW 'Task' 'Edit Custom Category API' 'New' $p6 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=4;"Microsoft.VSTS.Scheduling.CompletedWork"=4;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$t12=CW 'Task' 'Display product list on Custom Category Details Page' 'New' $p5 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=8;"Microsoft.VSTS.Scheduling.RemainingWork"=8;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S3"}
$t13=CW 'Task' 'Add API method remove assigned products from category' 'New' $p6 @{"Microsoft.VSTS.Common.Activity"="Development";"Microsoft.VSTS.Scheduling.OriginalEstimate"=4;"Microsoft.VSTS.Scheduling.CompletedWork"=4;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S3"}
$t14=CW 'Task' 'Order Template Upload is not working' 'New' $p3 @{"Microsoft.VSTS.Common.Activity"="Testing";"Microsoft.VSTS.Scheduling.OriginalEstimate"=4;"Microsoft.VSTS.Scheduling.RemainingWork"=4;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"}
# Task states
if($t1){UPD $t1 @{"System.State"="Active"}}
if($t3){UPD $t3 @{"System.State"="Active"}}
if($t4){UPD $t4 @{"System.State"="Closed"}}
if($t6){UPD $t6 @{"System.State"="Closed"}}
if($t7){UPD $t7 @{"System.State"="Closed"}}
if($t8){UPD $t8 @{"System.State"="Active"}}
if($t9){UPD $t9 @{"System.State"="Active"}}
if($t10){UPD $t10 @{"System.State"="Closed"}}
if($t11){UPD $t11 @{"System.State"="Closed"}}
if($t13){UPD $t13 @{"System.State"="Closed"}}

# --- BUGS (8) ---
$b1=CW 'Bug' 'Incorrect CarrierCode Sent to EcomApi' 'New' 0 @{"Microsoft.VSTS.Common.Severity"="1 - Critical";"Microsoft.VSTS.Common.Priority"=1;"System.Tags"="carrier;ERP;critical;hotfix";"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"} "<h3>Repro Steps</h3><ol><li>Add LTL-eligible product to cart</li><li>Proceed to checkout</li><li>Select LTL shipping</li><li>Submit order</li></ol><h3>Expected</h3><p>CarrierCode=LTL sent to API</p><h3>Actual</h3><p>CarrierCode=PARCEL sent incorrectly</p>"
$b2=CW 'Bug' 'Incorrect Terms Flag sent to EcomApi' 'New' 0 @{"Microsoft.VSTS.Common.Severity"="1 - Critical";"Microsoft.VSTS.Common.Priority"=1;"System.Tags"="terms;checkout;guest;compliance";"System.IterationPath"="YASH-DevOps-Serverless\Sprint 1"}
$b3=CW 'Bug' 'Duplicate Categories Being Displayed' 'New' 0 @{"Microsoft.VSTS.Common.Severity"="2 - High";"Microsoft.VSTS.Common.Priority"=2;"System.Tags"="category;display;UI";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"}
$b4=CW 'Bug' 'Compare page - Attributes comparison table UI issue' 'New' 0 @{"Microsoft.VSTS.Common.Severity"="3 - Medium";"Microsoft.VSTS.Common.Priority"=3;"System.Tags"="compare;UI;table";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S1"}
$b5=CW 'Bug' 'Pagination settings are not working as expected' 'New' 0 @{"Microsoft.VSTS.Common.Severity"="2 - High";"Microsoft.VSTS.Common.Priority"=2;"System.Tags"="pagination;PLP;regression";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$b6=CW 'Bug' 'Product image not displayed when adding through quick order' 'New' 0 @{"Microsoft.VSTS.Common.Severity"="3 - Medium";"Microsoft.VSTS.Common.Priority"=3;"System.Tags"="image;quickorder;display";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$b7=CW 'Bug' 'Javascript errors in console during checkout' 'New' 0 @{"Microsoft.VSTS.Common.Severity"="2 - High";"Microsoft.VSTS.Common.Priority"=2;"System.Tags"="javascript;checkout;console";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S3"}
$b8=CW 'Bug' 'Search results show HTML entities' 'New' 0 @{"Microsoft.VSTS.Common.Severity"="4 - Low";"Microsoft.VSTS.Common.Priority"=4;"System.Tags"="search;encoding;display";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S3"}
if($b1){UPD $b1 @{"System.State"="Active"}}
if($b2){UPD $b2 @{"System.State"="Resolved"}}
if($b3){UPD $b3 @{"System.State"="Active"}}
if($b5){UPD $b5 @{"System.State"="Closed"}}
if($b7){UPD $b7 @{"System.State"="Closed"}}

# --- TEST ITEMS (5) ---
$tp1=CW 'Test Plan' 'Release 2.0 Full Regression Plan' 'Active' 0 @{"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$ts1=CW 'Test Suite' 'Search and Filter Regression Suite' 'In Progress' $tp1 @{"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$ts2=CW 'Test Suite' 'Checkout Flow Suite' 'In Progress' $tp1 @{"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$tc1=CW 'Test Case' 'Verify Out of Stock badge on PLP' 'Design' 0 @{"Microsoft.VSTS.Common.Priority"=2;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}
$tc2=CW 'Test Case' 'Verify PO number validation on checkout' 'Design' 0 @{"Microsoft.VSTS.Common.Priority"=1;"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S2"}

# --- ISSUE (1) ---
$iss=CW 'Issue' 'Idea: Add voice search to product catalog' 'Active' 0 @{"Microsoft.VSTS.Common.Priority"=4;"System.Tags"="idea;voice;search;future";"System.IterationPath"="YASH-DevOps-Serverless\Serverless_S3"}

# --- COMMENTS ---
if($p1){AddComment $p1 "<p><b>Design Review</b></p><p>Filter panel goes on left sidebar with real-time count badges. Clear-all button at top.</p><p><img src='https://via.placeholder.com/400x300.png?text=Faceted+Filter+Wireframe' alt='wireframe'/></p>"}
if($p1){AddComment $p1 "<p>Updated AC after sprint review. Added: filter results must update in less than 2 seconds.</p>"}
if($p3){AddComment $p3 "<p><b>API Integration</b></p><p>PO maps to ERP field <code>CustomerPO</code>. Max 20 chars, alphanumeric+dashes.</p><p><img src='https://via.placeholder.com/500x300.png?text=Checkout+Flow' alt='checkout'/></p>"}
if($b1){AddComment $b1 "<p><b>Root Cause</b></p><p>CarrierCode mapping was incorrect for LTL shipments. Fixed in commit <code>abc123f</code>.</p><p><img src='https://via.placeholder.com/500x200.png?text=Fix+Before+After' alt='fix'/></p>"}
if($b2){AddComment $b2 "<p>Guest checkout bypasses terms acceptance flag. <b>Compliance risk</b>. Legal notified. Setting P1.</p>"}

# --- CROSS LINKS ---
if($b1 -and $p3){AddLink $b1 $p3}
if($b2 -and $p3){AddLink $b2 $p3}
if($b3 -and $p5){AddLink $b3 $p5}
if($p2 -and $f1){AddLink $p2 $f1 "System.LinkTypes.Dependency-Reverse"}
if($p5 -and $f3){AddLink $p5 $f3 "System.LinkTypes.Dependency-Reverse"}

Write-Host "`n=== DONE ===" -ForegroundColor Green
Write-Host "Epics: 4 | Features: 6 | PBIs: 8 | CRs: 2 | Tasks: 14 | Bugs: 8 | Test: 5 | Issue: 1"
Write-Host "TOTAL: 48 items with client-style titles, states, fields, comments, and links"
