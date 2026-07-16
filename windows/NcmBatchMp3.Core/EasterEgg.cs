namespace NcmBatchMp3.Core;

public static class EasterEgg
{
    private static readonly DateTime BaseDate = new(2024, 1, 30);

    public static int DaysTogether(DateTime now)
    {
        return (now.Date - BaseDate).Days;
    }

    public static string Message(DateTime now)
    {
        return $"谨以此app，纪念Eric与Eva认识{DaysTogether(now)}天！";
    }
}
