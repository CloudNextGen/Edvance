public with sharing class Assignmentadmincontroller {
    public class AssignmentOption implements Comparable {
        @AuraEnabled public Id assignmentId;
        @AuraEnabled public String assignmentName;
        @AuraEnabled public Decimal questionCount;
        @AuraEnabled public Decimal sequence;
        @AuraEnabled public String status;          // 'Not Assigned' | 'Eligible' | 'Completed' | 'Locked'
        @AuraEnabled public Id eligibilityId;        // null when status == 'Not Assigned'
        @AuraEnabled public Boolean alreadyAssigned; // true for Eligible / Completed / Locked
        @AuraEnabled public Boolean canReassign;     // true for Completed / Locked only
        @AuraEnabled public Boolean canRevoke;

        public AssignmentOption(Assignment__c asm, Assignment_Eligibility__c existing) {
            this.assignmentId = asm.Id;
            this.assignmentName = asm.Name;
            this.questionCount = asm.Total_Question_Count__c;
            this.sequence = asm.Sequence__c;

            if (existing == null || existing.Eligibility_Status__c == 'Revoked') {
                this.status = 'Not Assigned';
                this.eligibilityId = existing == null ? null : existing.Id;
                this.alreadyAssigned = false;
                this.canReassign = false;
                this.canRevoke = false;
            } else {
                this.status = existing.Eligibility_Status__c;
                this.eligibilityId = existing.Id;
                this.alreadyAssigned = true;
                this.canReassign = (existing.Eligibility_Status__c == 'Completed' || existing.Eligibility_Status__c == 'Locked');
                this.canRevoke = true;
            }
        }

        public Integer compareTo(Object compareTo) {
            AssignmentOption other = (AssignmentOption) compareTo;
            Decimal thisSeq = this.sequence == null ? 9999 : this.sequence;
            Decimal otherSeq = other.sequence == null ? 9999 : other.sequence;
            if (thisSeq != otherSeq) {
                return thisSeq > otherSeq ? 1 : -1;
            }
            return this.assignmentName.compareTo(other.assignmentName);
        }
    }

    public class CategoryNode implements Comparable {
        @AuraEnabled public Id categoryId;
        @AuraEnabled public String categoryName;
        @AuraEnabled public List<AssignmentOption> assignments;

        public CategoryNode(Id categoryId, String categoryName) {
            this.categoryId = categoryId;
            this.categoryName = categoryName;
            this.assignments = new List<AssignmentOption>();
        }

        public Integer compareTo(Object compareTo) {
            CategoryNode other = (CategoryNode) compareTo;
            Integer thisNum = AssignmentAdminController.extractNumber(this.categoryName);
            Integer otherNum = AssignmentAdminController.extractNumber(other.categoryName);
            if (thisNum != otherNum) {
                return thisNum - otherNum;
            }
            return this.categoryName.compareTo(other.categoryName);
        }
    }

    @AuraEnabled
    public static List<CategoryNode> getAssignableAssignmentsTree(Id contactId, String searchTerm) {
        String term = String.isBlank(searchTerm) ? '' : searchTerm.trim().toLowerCase();

        Map<Id, Assignment_Eligibility__c> eligByAssignmentId = new Map<Id, Assignment_Eligibility__c>();
        for (Assignment_Eligibility__c elig : [
            SELECT Id, Assignment__c, Eligibility_Status__c
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :contactId
        ]) {
            eligByAssignmentId.put(elig.Assignment__c, elig);
        }

        Map<Id, Category__c> categoriesById = new Map<Id, Category__c>([
            SELECT Id, Name FROM Category__c
        ]);

        Map<Id, CategoryNode> nodesByCategory = new Map<Id, CategoryNode>();

        for (Assignment__c asm : [
            SELECT Id, Name, Category__c, Total_Question_Count__c, Sequence__c
            FROM Assignment__c
            WHERE Category__c != null
        ]) {
            if (!String.isBlank(term)) {
                Boolean nameMatches = asm.Name != null && asm.Name.toLowerCase().contains(term);
                Category__c cat = categoriesById.get(asm.Category__c);
                Boolean categoryMatches = cat != null && cat.Name != null && cat.Name.toLowerCase().contains(term);
                if (!nameMatches && !categoryMatches) {
                    continue;
                }
            }

            if (!nodesByCategory.containsKey(asm.Category__c)) {
                Category__c cat = categoriesById.get(asm.Category__c);
                if (cat == null) continue;
                nodesByCategory.put(asm.Category__c, new CategoryNode(cat.Id, cat.Name));
            }

            Assignment_Eligibility__c existing = eligByAssignmentId.get(asm.Id);
            nodesByCategory.get(asm.Category__c).assignments.add(new AssignmentOption(asm, existing));
        }

        List<CategoryNode> result = new List<CategoryNode>();
        for (CategoryNode node : nodesByCategory.values()) {
            node.assignments.sort();
            result.add(node);
        }
        result.sort();
        return result;
    }

    @AuraEnabled
    public static void assignAssignmentsToContact(Id contactId, List<Id> assignmentIds) {
        if (assignmentIds == null || assignmentIds.isEmpty()) {
            throw new AuraHandledException('No assignments selected.');
        }

        Contact con = [SELECT Id, Name FROM Contact WHERE Id = :contactId LIMIT 1];

        Map<Id, Assignment__c> assignmentsMap = new Map<Id, Assignment__c>([
            SELECT Id, Name FROM Assignment__c WHERE Id IN :assignmentIds
        ]);

        Map<Id, Assignment_Eligibility__c> existingByAssignmentId = new Map<Id, Assignment_Eligibility__c>();
        for (Assignment_Eligibility__c elig : [
            SELECT Id, Assignment__c, Eligibility_Status__c
            FROM Assignment_Eligibility__c
            WHERE Contact__c = :contactId AND Assignment__c IN :assignmentIds
        ]) {
            existingByAssignmentId.put(elig.Assignment__c, elig);
        }

        List<Assignment_Eligibility__c> toInsert = new List<Assignment_Eligibility__c>();
        List<Assignment_Eligibility__c> toReactivate = new List<Assignment_Eligibility__c>();
        for (Id assignmentId : assignmentIds) {
            Assignment_Eligibility__c existing = existingByAssignmentId.get(assignmentId);
            if (existing != null) {
                if (existing.Eligibility_Status__c == 'Revoked') {
                    existing.Eligibility_Status__c = 'Eligible';
                    toReactivate.add(existing);
                }
                continue;
            }
            Assignment__c asm = assignmentsMap.get(assignmentId);
            if (asm == null) continue;

            String eligName = asm.Name + ' ' + con.Name;

            Assignment_Eligibility__c elig = new Assignment_Eligibility__c();
            elig.Name = eligName.length() > 80 ? eligName.left(80) : eligName;
            elig.Contact__c = contactId;
            elig.Assignment__c = assignmentId;
            elig.Eligibility_Status__c = 'Eligible';
            elig.Current_Attempt_Number__c = 1;
            toInsert.add(elig);
        }

        if (!toInsert.isEmpty()) {
            insert as user toInsert;
        }
        if (!toReactivate.isEmpty()) {
            update as user toReactivate;
        }
    }

    @AuraEnabled
    public static void revokeAssignmentFromContact(Id contactId, Id eligibilityId) {
        if (contactId == null || eligibilityId == null) {
            throw new AuraHandledException('A team member and assignment eligibility are required.');
        }

        List<Assignment_Eligibility__c> eligibilityRecords = [
            SELECT Id, Eligibility_Status__c
            FROM Assignment_Eligibility__c
            WHERE Id = :eligibilityId AND Contact__c = :contactId
            LIMIT 1
            FOR UPDATE
        ];
        if (eligibilityRecords.isEmpty()) {
            throw new AuraHandledException('This assignment is not assigned to the selected team member.');
        }
        if (eligibilityRecords[0].Eligibility_Status__c == 'Revoked') {
            throw new AuraHandledException('This assignment has already been revoked.');
        }

        eligibilityRecords[0].Eligibility_Status__c = 'Revoked';
        update as user eligibilityRecords[0];
    }

    @AuraEnabled
    public static void reassignAssignment(Id eligibilityId) {
        Assignment_Eligibility__c elig = [
            SELECT Id, Eligibility_Status__c
            FROM Assignment_Eligibility__c
            WHERE Id = :eligibilityId
            LIMIT 1
        ];

        // Mirrors the existing admin reset behavior referenced in submitAssignment:
        // flips status back to Eligible only, Current_Attempt_Number__c is left as-is
        // since submitAssignment derives the real attempt number from prior submission count.
        elig.Eligibility_Status__c = 'Eligible';
        update as user elig;
    }

    public static Integer extractNumber(String str) {
        if (String.isBlank(str)) return 9999;

        String digits = '';
        for (Integer i = 0; i < str.length(); i++) {
            String ch = str.substring(i, i + 1);
            if (ch.isNumeric()) {
                digits += ch;
            } else if (digits.length() > 0) {
                break;
            }
        }

        return String.isNotBlank(digits) ? Integer.valueOf(digits) : 9999;
    }
}