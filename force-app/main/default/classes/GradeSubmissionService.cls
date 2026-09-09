public with sharing class GradeSubmissionService {

    public interface IEinsteinCaller {
        String generate(String questionText, String expectedAnswer, String userAnswer, Decimal maxPoints);
    }

    @TestVisible
    private static IEinsteinCaller einsteinCaller = new RealEinsteinCaller();

    @InvocableMethod(label='Grade Submission' description='Grades all ungraded Question_Response__c records for a submission via Einstein.')
    public static void gradeSubmission(List<Id> submissionIds) {
        
        if (submissionIds == null || submissionIds.isEmpty()) {
            return;
        }
        gradeResponsesForSubmissions(submissionIds);
        
    }
    
    public static void gradeResponsesForSubmissions(List<Id> submissionIds) {

        List<Question_Response__c> responses = [
            SELECT Id,
                   User_Answer__c,
                   Assignment_Question__r.Question_Text__c,
                   Assignment_Question__r.Expected_Answer__c,
                   Assignment_Question__r.Max_Points__c
            FROM   Question_Response__c
            WHERE  User_Submission__c IN :submissionIds
            WITH   USER_MODE
        ];

        if (responses.isEmpty()) {
            return;
        }

        List<Question_Response__c> toUpdate = new List<Question_Response__c>();

        for (Question_Response__c resp : responses) {
            Decimal maxPoints = resp.Assignment_Question__r.Max_Points__c;

            try {
                String rawText = einsteinCaller.generate(
                    resp.Assignment_Question__r.Question_Text__c,
                    resp.Assignment_Question__r.Expected_Answer__c,
                    resp.User_Answer__c,
                    maxPoints
                );

                ScoreResult result = parseScoreResult(rawText, maxPoints);
                resp.AI_Grade__c    = result.score;
                resp.AI_Feedback__c = result.feedback;

            } catch (Exception e) {
                ErrorLogger.log(e);
                resp.AI_Grade__c    = 0;
                resp.AI_Feedback__c = 'Grading could not be completed automatically. ' +
                                      'Please contact your administrator. (' + e.getMessage() + ')';
            }
            toUpdate.add(resp);
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }

        markSubmissionsGraded(submissionIds);
    }

    // ─── Robust JSON parsing with graceful fallback ────────────────────────
    @TestVisible
    private static ScoreResult parseScoreResult(String raw, Decimal maxPoints) {
        ScoreResult result = new ScoreResult();

        String cleaned = raw == null ? '' : raw.trim();
        if (cleaned.startsWith('```')) {
            cleaned = cleaned.substringAfter('\n');
            cleaned = cleaned.substringBeforeLast('```');
        }

        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);

            Object scoreObj = parsed.get('score');
            Decimal score = scoreObj instanceof Decimal ? (Decimal) scoreObj
                           : Decimal.valueOf(String.valueOf(scoreObj));

            Decimal cap = maxPoints == null ? 5 : maxPoints;
            if (score < 0) score = 0;
            if (score > cap) score = cap;

            result.score    = score;
            result.feedback = String.valueOf(parsed.get('feedback'));

        } catch (Exception e) {
            ErrorLogger.log(e);
            Matcher m = Pattern.compile('"score"\\s*:\\s*([0-9.]+)').matcher(cleaned);
            if (m.find()) {
                result.score = Decimal.valueOf(m.group(1));
            } else {
                result.score = 0;
            }
            result.feedback = 'AI response could not be fully parsed. Raw score extracted where possible.';
        }

        return result;
    }
    

    // ─── Mark parent Submission as Graded once all child Responses are done ──
    private static void markSubmissionsGraded(List<Id> submissionIds) {
        List<User_Submission__c> submissions = [
            SELECT Id, Status__c,
                   (SELECT Id, AI_Grade__c FROM Question_Response__r)
            FROM   User_Submission__c
            WHERE  Id IN :submissionIds
            WITH   USER_MODE
        ];

        List<User_Submission__c> toUpdate = new List<User_Submission__c>();

        for (User_Submission__c sub : submissions) {
            Boolean allGraded = true;
            for (Question_Response__c r : sub.Question_Response__r) {
                if (r.AI_Grade__c == null) {
                    allGraded = false;
                    break;
                }
            }
            if (allGraded && sub.Status__c != 'Graded') {
                sub.Status__c = 'Graded';
                toUpdate.add(sub);
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    private class RealEinsteinCaller implements IEinsteinCaller {
        public String generate(String questionText, String expectedAnswer, String userAnswer, Decimal maxPoints) {
            
            ConnectApi.WrappedValue qVal = new ConnectApi.WrappedValue();
            qVal.value = questionText;

            ConnectApi.WrappedValue eVal = new ConnectApi.WrappedValue();
            eVal.value = expectedAnswer;

            ConnectApi.WrappedValue aVal = new ConnectApi.WrappedValue();
            aVal.value = userAnswer;

            ConnectApi.WrappedValue mVal = new ConnectApi.WrappedValue();
            mVal.value = String.valueOf(maxPoints == null ? 5 : maxPoints);

            Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
            inputParams.put('Input:QuestionText', qVal);
            inputParams.put('Input:ExpectedAnswer', eVal);
            inputParams.put('Input:UserAnswer', aVal);
            inputParams.put('Input:MaxPoints', mVal);

            ConnectApi.EinsteinPromptTemplateGenerationsInput genInput =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            genInput.inputParams      = inputParams;
            genInput.isPreview        = false;
            genInput.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            genInput.additionalConfig.applicationName = 'PromptBuilderPreview';

            // Replace 'QA_Semantic_Builder' with the exact API Name shown on
            // your Prompt Template detail page in Setup → Prompt Builder.
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation genOutput =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'QA_Semantic_Builder',
                    genInput
                );

            return genOutput.generations[0].text;
            
        }
    }

    // ─── Score result wrapper ────────────────────────────────────────────────
    public class ScoreResult {
        public Decimal score;
        public String  feedback;
    }
}