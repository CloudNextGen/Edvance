public without sharing class InstructionController {

    private static final String PERM_HR = 'Portal_HR_Access';
    private static final String PERM_MENTOR = 'Portal_Mentor_Access';
    private static final String PERM_TEAM_MEMBER = 'Portal_Team_Member_Access';

    @AuraEnabled(cacheable=true)
    public static List<Instruction_Visiblity__mdt> getInstructions() {
        try {
            // Evaluated in-memory: completely bypasses PermissionSetAssignment SOQL restrictions
            Boolean isHR = FeatureManagement.checkPermission(PERM_HR);
            Boolean isMentor = FeatureManagement.checkPermission(PERM_MENTOR);
            Boolean hasTeamMember = FeatureManagement.checkPermission(PERM_TEAM_MEMBER);

            // Exclude Mentors from viewing pure Team Member instructions
            Boolean isPureTeamMember = hasTeamMember && !isMentor;

            // Load Custom Metadata without SOQL describe restrictions
            List<Instruction_Visiblity__mdt> allMetadata = Instruction_Visiblity__mdt.getAll().values();
            List<Instruction_Visiblity__mdt> visibleList = new List<Instruction_Visiblity__mdt>();

            for (Instruction_Visiblity__mdt item : allMetadata) {
                // Rule 1: Always include if checked for All
                if (item.All__c == true) {
                    visibleList.add(item);
                    continue;
                }

                // Rule 2: Role-specific matching
                Boolean canView = false;

                if (item.HR__c == true && isHR) {
                    canView = true;
                }
                if (item.MENTOR__c == true && isMentor) {
                    canView = true;
                }
                if (item.TEAM_MEMBER__c == true && isPureTeamMember) {
                    canView = true;
                }

                if (canView) {
                    visibleList.add(item);
                }
            }

            // Sort ascending by ORDER__c
            visibleList.sort(new InstructionOrderComparator());
            return visibleList;

        } catch (Exception e) {
            throw new AuraHandledException('Unable to retrieve instructions: ' + e.getMessage());
        }
    }

    public class InstructionOrderComparator implements System.Comparator<Instruction_Visiblity__mdt> {
        public Integer compare(Instruction_Visiblity__mdt o1, Instruction_Visiblity__mdt o2) {
            Decimal ord1 = o1.ORDER__c != null ? o1.ORDER__c : 99999;
            Decimal ord2 = o2.ORDER__c != null ? o2.ORDER__c : 99999;
            return (Integer)(ord1 - ord2);
        }
    }
}